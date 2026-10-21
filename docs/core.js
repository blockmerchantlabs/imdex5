// IMDEX5 site core: chain reads, quotes and transactions. No DOM here, so the same code runs
// in the page and in the fork test (node). Every figure is read from the chain.
(function (root) {
  "use strict";

  const C = {
    INDEX: "0xC5a8A9F9B12480B47456E3338695f6038c56e779",
    IMD: "0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7",
    POOL_MANAGER: "0x000000000004444c5dc75cB358380D2e3dE08A90",
    POOL_FEE: 12500,
    TICK_SPACING: 60,
    POOLS_SLOT: 6n,
    DEPLOY_BLOCK: 26242171,
    LAUNCH: 2361,
    CHAIN_ID: 1n,
    RPCS: ["https://ethereum-rpc.publicnode.com", "https://eth.llamarpc.com", "https://cloudflare-eth.com"],
  };

  const INDEX_ABI = [
    "function coins() view returns (tuple(address token, address hook, uint64 launch)[])",
    "function nextList() view returns (tuple(address token, address hook, uint64 launch)[])",
    "function listCount() view returns (uint256)",
    "function held(address) view returns (uint256)",
    "function owed(address, address) view returns (uint256)",
    "function idleImd() view returns (uint256)",
    "function feeImd() view returns (uint256)",
    "function openSince() view returns (uint64)",
    "function lastAsk() view returns (uint64)",
    "function answerHash() view returns (bytes32)",
    "function totalSupply() view returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
    "function mintFirst(uint256 imdIn, uint256[] minOut)",
    "function mint(uint256 shares, uint256 maxImdIn, uint256 minShares)",
    "function redeem(uint256 shares)",
    "function redeemToImd(uint256 shares, uint256 minImdOut)",
    "function claim(address coin)",
    "function ask()",
    "function closeRequest()",
    "function rebalance()",
    "event MintedFirst(address indexed to, uint256 imdIn, uint256 shares)",
    "event Minted(address indexed to, uint256 shares, uint256 imdPaid)",
    "event Redeemed(address indexed from, uint256 shares)",
    "event RedeemedToImd(address indexed from, uint256 shares, uint256 imdOut)",
    "event Rebalanced(address indexed caller)",
    "error ZeroAmount()", "error NotFirstMint()", "error FirstMintOnly()", "error BadLength()",
    "error BuyFailed(address coin)", "error TooExpensive(uint256 cost)", "error TooFewShares(uint256 shares)",
    "error NothingToPay()", "error TooLittleOut(uint256 out)", "error NothingOwed()", "error RequestOpen()",
    "error ListAwaitsRebalance()", "error AskTooSoon()", "error NoRequest()", "error TooEarly()",
    "error NoNextList()", "error NothingOut()", "error PoorFill()",
    "error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)",
    "error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)",
  ];
  const ERC20_ABI = [
    "function symbol() view returns (string)",
    "function balanceOf(address) view returns (uint256)",
    "function allowance(address, address) view returns (uint256)",
    "function approve(address, uint256) returns (bool)",
  ];
  const PM_ABI = ["function extsload(bytes32) view returns (bytes32)"];

  const E18 = 10n ** 18n;
  const Q192 = 1n << 192n;
  const ASK_INTERVAL = 7n * 24n * 3600n;
  const CLOSE_AFTER = 2n * 24n * 3600n;
  const ORACLE_COST = 75n * 10n ** 16n; // 0.5 IMD oracle + 0.25 IMD caller reward
  // Rough cost of a buy or sale beyond the index's own 0.50%: the 1.25% pool fee plus impact.
  const TRADE_COST_BPS = 250n;

  const ERRORS = {
    TooExpensive: "the buys would cost more than your limit; try a smaller amount",
    TooFewShares: "the pools filled short and fewer shares than your minimum would be issued",
    TooLittleOut: "the sale would pay less IMD than your minimum; try a smaller amount or redeem in coins",
    BuyFailed: "one coin's pool rejected the buy, so minting is paused until it trades again (redeem still works)",
    NothingOwed: "nothing of that coin is owed to this wallet",
    AskTooSoon: "the weekly question was asked less than 7 days ago",
    RequestOpen: "a question is already waiting for its answer",
    ListAwaitsRebalance: "a new list is waiting: run the rebalance first",
    NoNextList: "there is no new list to rebalance to",
    NoRequest: "no question is open",
    TooEarly: "a question can be closed only after two days",
    FirstMintOnly: "the first mint has not happened yet",
    NotFirstMint: "the first mint has already happened",
    ERC20InsufficientBalance: "this wallet does not hold enough",
    ERC20InsufficientAllowance: "the IMD approval is too low",
  };

  function readProvider(ethers, url) {
    return new ethers.JsonRpcProvider(url || C.RPCS[0], 1, { staticNetwork: true });
  }

  // IMD per coin, 18 decimals, from the v4 pool's sqrt price (every coin here has 18 decimals).
  async function poolPrice(ethers, provider, token, hook) {
    const tokenIsZero = BigInt(token) < BigInt(C.IMD);
    const [c0, c1] = tokenIsZero ? [token, C.IMD] : [C.IMD, token];
    const coder = ethers.AbiCoder.defaultAbiCoder();
    const poolId = ethers.keccak256(
      coder.encode(["address", "address", "uint24", "int24", "address"], [c0, c1, C.POOL_FEE, C.TICK_SPACING, hook])
    );
    const slot = ethers.keccak256(coder.encode(["bytes32", "uint256"], [poolId, C.POOLS_SLOT]));
    const pm = new ethers.Contract(C.POOL_MANAGER, PM_ABI, provider);
    const word = BigInt(await pm.extsload(slot));
    const sqrt = word & ((1n << 160n) - 1n);
    if (sqrt === 0n) return 0n;
    return tokenIsZero ? (sqrt * sqrt * E18) / Q192 : (Q192 * E18) / (sqrt * sqrt);
  }

  async function load(ethers, provider, account) {
    const x = new ethers.Contract(C.INDEX, INDEX_ABI, provider);
    const imd = new ethers.Contract(C.IMD, ERC20_ABI, provider);
    const [coins, next, listCount, idle, fee, supply, openSince, lastAsk, answerHash, block] = await Promise.all([
      x.coins(), x.nextList(), x.listCount(), x.idleImd(), x.feeImd(), x.totalSupply(),
      x.openSince(), x.lastAsk(), x.answerHash(), provider.getBlock("latest"),
    ]);
    const rows = await Promise.all(
      coins.map(async (c, i) => {
        const t = new ethers.Contract(c.token, ERC20_ABI, provider);
        const [symbol, held, price, owed] = await Promise.all([
          t.symbol().catch(() => "?"),
          x.held(c.token),
          poolPrice(ethers, provider, c.token, c.hook).catch(() => 0n),
          account ? x.owed(account, c.token) : 0n,
        ]);
        return {
          token: c.token, hook: c.hook, launch: Number(c.launch), symbol, held, price, owed,
          value: (held * price) / E18, listed: BigInt(i) < listCount,
        };
      })
    );
    const coinValue = rows.reduce((s, r) => s + r.value, 0n);
    const total = coinValue + idle;
    for (const r of rows) {
      r.weightBps = total > 0n ? (r.value * 10000n) / total : 0n;
      r.perShare = supply > 0n ? (r.held * E18) / supply : 0n;
    }
    const s = {
      rows, next, idle, fee, supply, total, coinValue,
      nav: supply > 0n ? (total * E18) / supply : 0n,
      idleWeightBps: total > 0n ? (idle * 10000n) / total : 0n,
      openSince: BigInt(openSince), lastAsk: BigInt(lastAsk), answerPending: answerHash !== ethers.ZeroHash,
      now: BigInt(block.timestamp), block: block.number,
      account: account || null, shares: 0n, imdBalance: 0n, allowance: 0n, imdOwed: 0n,
    };
    s.askAt = s.lastAsk + ASK_INTERVAL;
    s.canAsk = s.openSince === 0n && next.length === 0 && s.now >= s.askAt && fee >= ORACLE_COST;
    s.canClose = s.openSince !== 0n && s.now >= s.openSince + CLOSE_AFTER;
    s.canRebalance = next.length > 0;
    if (account) {
      const [shares, bal, allowance, imdOwed] = await Promise.all([
        x.balanceOf(account), imd.balanceOf(account), imd.allowance(account, C.INDEX), x.owed(account, C.IMD),
      ]);
      Object.assign(s, { shares, imdBalance: bal, allowance, imdOwed });
    }
    return s;
  }

  // Recent mints and redeems, newest first.
  async function activity(ethers, provider, limit) {
    const x = new ethers.Contract(C.INDEX, INDEX_ABI, provider);
    const head = await provider.getBlockNumber();
    const out = [];
    const step = 49000;
    for (let to = head; to >= C.DEPLOY_BLOCK && out.length < (limit || 20); to -= step + 1) {
      const from = Math.max(C.DEPLOY_BLOCK, to - step);
      const logs = await provider.getLogs({ address: C.INDEX, fromBlock: from, toBlock: to });
      for (const l of logs.reverse()) {
        let p;
        try { p = x.interface.parseLog(l); } catch (_) { continue; }
        if (!p) continue;
        out.push({ name: p.name, args: p.args, tx: l.transactionHash, block: l.blockNumber });
      }
    }
    return out.slice(0, limit || 20);
  }

  function explain(e) {
    const name = e && e.revert && e.revert.name;
    if (name && ERRORS[name]) return ERRORS[name];
    if (name) return name;
    if (e && (e.code === "ACTION_REJECTED" || e.code === 4001)) return "you cancelled it in the wallet";
    return (e && (e.shortMessage || e.message)) || String(e);
  }

  async function ensureApproval(ethers, signer, amount, onStep) {
    const owner = await signer.getAddress();
    const imd = new ethers.Contract(C.IMD, ERC20_ABI, signer);
    const allowed = await imd.allowance(owner, C.INDEX);
    if (allowed >= amount) return;
    onStep && onStep("Approve exactly " + ethers.formatEther(amount) + " IMD to the index in your wallet…");
    const tx = await imd.approve(C.INDEX, amount);
    await tx.wait();
  }

  // Mint for a budget of `budget` IMD. Returns the receipt. `slipBps` bounds how many fewer
  // shares than quoted you accept.
  async function mintFor(ethers, signer, budget, slipBps, onStep) {
    const provider = signer.provider;
    const s = await load(ethers, provider);
    const x = new ethers.Contract(C.INDEX, INDEX_ABI, signer);
    await ensureApproval(ethers, signer, budget, onStep);
    if (s.supply === 0n) {
      const minOut = firstMintMinOut(s, budget);
      await x.mintFirst.staticCall(budget, minOut);
      onStep && onStep("Confirm the first mint in your wallet…");
      return (await x.mintFirst(budget, minOut)).wait();
    }
    // shares the budget buys at NAV, less the 0.50% fee and the pools' cost, with a margin
    let shares = (budget * E18 * 10000n) / (s.nav * (10000n + 50n + TRADE_COST_BPS + 100n));
    for (let i = 0; i < 6; i++) {
      const minShares = (shares * (10000n - BigInt(slipBps))) / 10000n;
      try {
        await x.mint.staticCall(shares, budget, minShares);
        onStep && onStep("Confirm the mint in your wallet…");
        return (await x.mint(shares, budget, minShares)).wait();
      } catch (e) {
        if (!(e.revert && e.revert.name === "TooExpensive")) throw e;
        shares = (shares * 97n) / 100n;
      }
    }
    throw new Error("could not fit a mint inside this budget");
  }

  // The first mint spends (budget less the 0.50% fee) in equal parts on the listed coins. Each
  // coin must deliver at least FIRST_MIN_BPS of what its part buys at the pool's spot price, so
  // a pool that pays dust fails the whole mint instead of taking its fifth (pool fee 1.25%, a
  // transfer tax up to 2% and price impact fit inside the 7% margin; the fork test delivered 96-98%).
  const FIRST_MIN_BPS = 9300n;
  function firstMintMinOut(s, budget) {
    const listed = s.rows.filter((r) => r.listed);
    const part = (budget * 9950n) / 10000n / BigInt(listed.length);
    return listed.map((r) => {
      if (r.price === 0n) throw new Error(r.symbol + " has no pool price; the first mint would fail");
      return (((part * E18) / r.price) * FIRST_MIN_BPS) / 10000n;
    });
  }

  // Expected IMD from redeemToImd, before the caller's slippage margin.
  function quoteRedeemToImd(s, shares) {
    if (s.supply === 0n || shares === 0n) return 0n;
    const keep = shares === s.supply ? 10000n : 9950n;
    const coinPart = (s.coinValue * shares) / s.supply;
    const sold = (coinPart * (10000n - TRADE_COST_BPS)) / 10000n;
    const idlePart = (s.idle * shares) / s.supply;
    return ((sold + idlePart) * keep) / 10000n;
  }

  async function redeemToImdFor(ethers, signer, shares, slipBps, onStep) {
    const s = await load(ethers, signer.provider);
    const x = new ethers.Contract(C.INDEX, INDEX_ABI, signer);
    const minOut = (quoteRedeemToImd(s, shares) * (10000n - BigInt(slipBps))) / 10000n;
    await x.redeemToImd.staticCall(shares, minOut);
    onStep && onStep("Confirm the redeem to IMD in your wallet…");
    return (await x.redeemToImd(shares, minOut)).wait();
  }

  async function call(ethers, signer, fn, args, onStep) {
    const x = new ethers.Contract(C.INDEX, INDEX_ABI, signer);
    await x[fn].staticCall(...(args || []));
    onStep && onStep("Confirm in your wallet…");
    return (await x[fn](...(args || []))).wait();
  }

  const api = { C, INDEX_ABI, ERC20_ABI, readProvider, poolPrice, load, activity, explain, mintFor,
    quoteRedeemToImd, redeemToImdFor, call, ensureApproval, firstMintMinOut };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.IMDEX5 = api;
})(typeof window !== "undefined" ? window : globalThis);
