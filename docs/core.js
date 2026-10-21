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

  // The IMD side of a pool's active liquidity (its virtual reserve at the current price), used only
  // to warn about price impact; a failed read just means no warning.
  async function poolDepth(ethers, provider, token, hook) {
    const tokenIsZero = BigInt(token) < BigInt(C.IMD);
    const [c0, c1] = tokenIsZero ? [token, C.IMD] : [C.IMD, token];
    const coder = ethers.AbiCoder.defaultAbiCoder();
    const poolId = ethers.keccak256(
      coder.encode(["address", "address", "uint24", "int24", "address"], [c0, c1, C.POOL_FEE, C.TICK_SPACING, hook])
    );
    const base = BigInt(ethers.keccak256(coder.encode(["bytes32", "uint256"], [poolId, C.POOLS_SLOT])));
    const pm = new ethers.Contract(C.POOL_MANAGER, PM_ABI, provider);
    const [w0, w3] = await Promise.all([pm.extsload(ethers.toBeHex(base, 32)), pm.extsload(ethers.toBeHex(base + 3n, 32))]);
    const sqrt = BigInt(w0) & ((1n << 160n) - 1n);
    const liq = BigInt(w3) & ((1n << 128n) - 1n);
    if (sqrt === 0n) return null;
    return tokenIsZero ? (liq * sqrt) >> 96n : (liq << 96n) / sqrt;
  }

  // Execution price impact, in basis points, of putting `amount` IMD through a pool of `depth`.
  function impactBps(amount, depth) {
    if (!depth || amount === 0n) return 0n;
    return (amount * 10000n) / (depth + amount);
  }
  // The worst single-pool impact of a mint of `budget` IMD (first mint: equal parts; later: by value).
  function mintImpactBps(s, budget) {
    const listed = s.rows.filter((r) => r.listed);
    let worst = 0n;
    for (const r of s.supply === 0n ? listed : s.rows) {
      const part = s.supply === 0n ? (budget * 9950n) / 10000n / BigInt(listed.length)
        : s.coinValue > 0n ? (budget * r.value) / s.coinValue : 0n;
      const b = impactBps(part, r.imdDepth);
      if (b > worst) worst = b;
    }
    return worst;
  }
  // The worst single-pool impact of selling `shares`' part of each coin for IMD.
  function redeemImpactBps(s, shares) {
    let worst = 0n;
    for (const r of s.rows) {
      const b = impactBps(s.supply > 0n ? (r.value * shares) / s.supply : 0n, r.imdDepth);
      if (b > worst) worst = b;
    }
    return worst;
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
        const [symbol, held, price, owed, imdDepth] = await Promise.all([
          t.symbol().catch(() => "?"),
          x.held(c.token),
          poolPrice(ethers, provider, c.token, c.hook).catch(() => null),
          account ? x.owed(account, c.token) : 0n,
          poolDepth(ethers, provider, c.token, c.hook).catch(() => null),
        ]);
        // a price that could not be read is null, never 0: quotes refuse it (audit c104e817, M2)
        const priceOk = price !== null && price > 0n;
        return {
          token: c.token, hook: c.hook, launch: Number(c.launch), symbol, held, owed, priceOk, imdDepth,
          price: priceOk ? price : 0n, value: priceOk ? (held * price) / E18 : 0n, listed: BigInt(i) < listCount,
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
      pricesOk: rows.every((r) => r.priceOk || (!r.listed && r.held === 0n)),
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

  // `op` is "first", "mint" or another label, so one error can read right for each action.
  function explain(e, op) {
    const name = e && e.revert && e.revert.name;
    if (name === "TooLittleOut" && op === "first")
      return "a coin's pool would deliver less than the minimum (its price moved, or the amount is too large for that pool); try a smaller amount";
    if (name === "ERC20InsufficientBalance" && isIndex(e.revert.args && e.revert.args[0]))
      return "the pools cannot fill this size at the quoted price; try a smaller amount";
    if (name && ERRORS[name]) return ERRORS[name];
    if (name) return name;
    if (e && (e.code === "ACTION_REJECTED" || e.code === 4001)) return "you cancelled it in the wallet";
    return (e && (e.shortMessage || e.message)) || String(e);
  }

  function isIndex(a) {
    try { return a && BigInt(a) === BigInt(C.INDEX); } catch (_) { return false; }
  }
  function tooDear(e) {
    const r = e && e.revert;
    return !!r && (r.name === "TooExpensive" || (r.name === "ERC20InsufficientBalance" && isIndex(r.args && r.args[0])));
  }

  // The later-mint quote, shared by the page and the transaction so both show and sign the same
  // numbers: shares the budget buys at NAV (less the 0.50% fee, the pools' cost and a margin), and
  // the floor the page shows as "at least".
  function quoteMint(s, budget, slipBps) {
    if (s.supply === 0n || s.nav === 0n) return null;
    const shares = (budget * E18 * 10000n) / (s.nav * (10000n + 50n + TRADE_COST_BPS + 100n));
    return { shares, minShares: (shares * (10000n - BigInt(slipBps))) / 10000n };
  }

  function needPrices(s) {
    const bad = s.rows.find((r) => !r.priceOk && (r.listed || r.held > 0n));
    if (bad) throw new Error(bad.symbol + "'s pool price could not be read; nothing was sent. Try again in a moment");
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

  // Mint for a budget of `budget` IMD. Returns the receipt. Every limit is fixed from one read of
  // the wallet's own node before any wallet prompt (audit c104e817, L3), and the signed floor is
  // never below the "at least" the page showed (M1): a retry after TooExpensive lowers the shares
  // asked for, never the floor, and stops once the shares would fall under it.
  async function mintFor(ethers, signer, budget, slipBps, onStep) {
    const s = await load(ethers, signer.provider);
    needPrices(s);
    const x = new ethers.Contract(C.INDEX, INDEX_ABI, signer);
    if (s.supply === 0n) {
      const minOut = firstMintMinOut(s, budget);
      await ensureApproval(ethers, signer, budget, onStep);
      await x.mintFirst.staticCall(budget, minOut);
      onStep && onStep("Confirm the first mint in your wallet…");
      return (await x.mintFirst(budget, minOut)).wait();
    }
    const q = quoteMint(s, budget, slipBps);
    await ensureApproval(ethers, signer, budget, onStep);
    let shares = q.shares;
    while (shares >= q.minShares) {
      try {
        await x.mint.staticCall(shares, budget, q.minShares);
        onStep && onStep("Confirm the mint in your wallet…");
        return (await x.mint(shares, budget, q.minShares)).wait();
      } catch (e) {
        if (!tooDear(e)) throw e;
        shares = (shares * 99n) / 100n;
      }
    }
    throw new Error("at today's pool prices this budget cannot buy the minimum shown (the amount is too large for the pools, or prices moved); nothing was sent. Try a smaller amount or refresh");
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
    needPrices(s);
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
    quoteRedeemToImd, redeemToImdFor, call, ensureApproval, firstMintMinOut, quoteMint, needPrices,
    poolDepth, impactBps, mintImpactBps, redeemImpactBps };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.IMDEX5 = api;
})(typeof window !== "undefined" ? window : globalThis);
