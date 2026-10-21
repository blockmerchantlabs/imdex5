// IMDEX5 site: page wiring. Chain logic lives in core.js.
(function () {
  "use strict";
  const X = window.IMDEX5;
  const $ = (id) => document.getElementById(id);
  const E18 = 10n ** 18n;
  const SLIP_BPS = 300; // 3%: the least you accept below the quote

  let reader = null;
  let browser = null; // ethers BrowserProvider
  let account = null;
  let state = null;
  let busy = false; // a wallet call is in flight: every action button stays disabled

  function lockIfBusy() {
    if (!busy) return;
    document.querySelectorAll("#act button:not([role=tab]):not(.fit), #keepers button").forEach((b) => (b.disabled = true));
  }

  function fmt(v, dp) {
    const n = Number(ethers.formatEther(v));
    if (n === 0) return "0";
    const d = dp === undefined ? (n >= 1000 ? 0 : n >= 1 ? 4 : 6) : dp;
    if (n < 10 ** -d) return n.toExponential(2);
    return n.toLocaleString("en-US", { maximumFractionDigits: d });
  }
  // Coin symbols come from whatever tokens the oracle lists, so they are untrusted text.
  function esc(t) {
    return String(t).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }
  // Logos kept in this site (coins/), by token address: from each launch's IMD logo job, and ZTO's
  // from IMD Radar. A coin without one gets a lettered badge.
  const LOGOS = {
    "0x53d0ea0a685220718dc6a0a6e4617194c6f37921": "coins/1282.png",
    "0xfa0efea559bde229031c2b0a219472316647759c": "coins/1283.png",
    "0xd782bdea4ef02a0bd391eb9089470c8080f0a68e": "coins/737.png",
    "0x1ae93a4d9cc0b41c594d00387b6f832a88f729b7": "coins/1175.png",
  };
  function logo(r) {
    const src = LOGOS[r.token.toLowerCase()];
    if (src) return '<img class="coin" src="' + src + '" alt="" width="24" height="24">';
    const letters = esc(String(r.symbol).replace(/[^A-Za-z0-9]/g, "").slice(0, 2).toUpperCase() || "?");
    return '<span class="coin mono m' + (Number(BigInt(r.token) % 6n)) + '" aria-hidden="true">' + letters + "</span>";
  }
  function pct(bps) { return (Number(bps) / 100).toFixed(1) + "%"; }
  function short(a) { return a.slice(0, 6) + "…" + a.slice(-4); }
  function when(ts) {
    if (!ts) return "never";
    return new Date(Number(ts) * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC";
  }
  function seg(bps) {
    const on = Math.round(Number(bps) / 500); // one cell per 5%
    let h = '<span class="seg" aria-hidden="true">';
    for (let i = 0; i < 6; i++) h += '<i class="' + (i < on ? "on" : "") + '"></i>';
    return h + "</span>";
  }
  function setStatus(msg, kind) {
    const el = $("status");
    el.textContent = msg || "";
    el.className = "status" + (kind ? " " + kind : "");
  }
  function parse(v) {
    try {
      const s = String(v || "").trim();
      if (!s) return 0n;
      return ethers.parseEther(s);
    } catch (_) { return -1n; }
  }

  async function connectReader() {
    for (const url of X.C.RPCS) {
      try {
        const p = X.readProvider(ethers, url);
        await p.getBlockNumber();
        return p;
      } catch (_) {}
    }
    throw new Error("no Ethereum node answered");
  }

  function render() {
    const s = state;
    $("nav").textContent = s.supply > 0n ? fmt(s.nav, 4) + " IMD" : "not minted yet";
    $("tvl").textContent = fmt(s.total, 2) + " IMD";
    $("supply").textContent = fmt(s.supply, 4);
    $("state").innerHTML = s.supply > 0n ? '<span class="live">Live</span>' : "Awaiting first mint";
    $("block").textContent = "Ethereum block " + s.block;
    $("feeres").textContent = fmt(s.fee, 4);

    let h = "";
    for (const r of s.rows) {
      const name = esc(r.symbol) + ' <span class="tag">#' + r.launch + (r.listed ? "" : " · leaving") + "</span>";
      h += "<tr><td>" + logo(r) + "<a href=\"https://etherscan.io/token/" + r.token + "\" target=\"_blank\" rel=\"noopener\">" + name + "</a></td>" +
        '<td class="num">' + seg(r.weightBps) + pct(r.weightBps) + "</td>" +
        '<td class="num">' + fmt(r.perShare, 2) + "</td>" +
        '<td class="num">' + fmt(r.price, 8) + "</td>" +
        '<td class="num">' + fmt(r.value, 4) + "</td></tr>";
    }
    h += '<tr><td><span class="coin mono m0" aria-hidden="true">IMD</span>Idle IMD</td><td class="num">' + seg(s.idleWeightBps) + pct(s.idleWeightBps) +
      '</td><td class="num">' + (s.supply > 0n ? fmt((s.idle * E18) / s.supply, 4) : "0") +
      '</td><td class="num">1</td><td class="num">' + fmt(s.idle, 4) + "</td></tr>";
    $("rows").innerHTML = h;

    // keepers
    const askReady = s.now >= s.askAt;
    $("kAsk").textContent = "last asked " + when(s.lastAsk) + (!askReady ? " · next from " + when(s.askAt)
      : s.canAsk ? " · can ask now" : s.fee < 75n * 10n ** 16n ? " · waits for 0.75 IMD in the reserve" : "");
    $("kOpen").textContent = s.openSince ? "since " + when(s.openSince) : s.answerPending ? "answered, waiting for submit" : "none";
    $("kNext").textContent = s.next.length ? s.next.map((c) => "#" + c.launch).join(", ") : "none";
    $("kFee").textContent = fmt(s.fee, 4) + " IMD (0.75 IMD per weekly question)";
    $("doAsk").disabled = !account || !s.canAsk;
    $("doRebalance").disabled = !account || !s.canRebalance;
    $("doClose").disabled = !account || !s.canClose;

    // wallet
    if (account) {
      let m = '<span class="k">Wallet</span><span>' + short(account) + "</span>" +
        '<span class="k">IMD</span><span>' + fmt(s.imdBalance, 4) + "</span>" +
        '<span class="k">IMDEX5</span><span>' + fmt(s.shares, 4) +
        (s.supply > 0n && s.shares > 0n ? " ≈ " + fmt((s.shares * s.nav) / E18, 4) + " IMD" : "") + "</span>";
      $("mine").innerHTML = m;
      const owed = s.rows.filter((r) => r.owed > 0n);
      if (s.imdOwed > 0n) owed.push({ symbol: "IMD", token: X.C.IMD, owed: s.imdOwed });
      $("owedList").innerHTML = owed.length
        ? owed.map((r) => '<div class="row"><span>' + fmt(r.owed, 4) + " " + esc(r.symbol) + '</span><button data-claim="' + esc(r.token) + '"' + (busy ? " disabled" : "") + ">Claim</button></div>").join("")
        : "Nothing is owed to this wallet.";
    }
    quoteBuy();
    quoteSell();
    lockIfBusy();
  }

  function quoteBuy() {
    const s = state;
    const amt = parse($("buyAmt").value);
    const go = $("buyGo");
    go.disabled = true;
    if (!s) return;
    if (amt < 0n) { $("buyQuote").textContent = "That is not a number."; return; }
    if (amt === 0n) { $("buyQuote").textContent = s.supply === 0n ? "No one has minted yet: the first mint sets one IMDEX5 per IMD invested." : "Enter an amount."; return; }
    if (s.supply === 0n) {
      const n = BigInt(s.rows.filter((r) => r.listed).length);
      $("buyQuote").textContent = "First mint: about " + fmt((amt * 9950n) / 10000n, 4) + " IMDEX5, buying " + n + " coins with " + fmt((amt * 9950n) / 10000n / n, 4) + " IMD each. Each coin must deliver at least 93% of its quote at the pool price, or nothing happens.";
    } else {
      if (!s.pricesOk) { $("buyQuote").textContent = "A coin's pool price could not be read just now, so minting waits for the next refresh."; return; }
      const q = X.quoteMint(s, amt, SLIP_BPS);
      $("buyQuote").textContent = "About " + fmt(q.shares, 4) + " IMDEX5 (at least " + fmt(q.minShares, 4) + ", or nothing happens). Unused IMD is refunded.";
    }
    if (!account) { go.textContent = "Connect a wallet to mint"; return; }
    if (amt > s.imdBalance) { go.textContent = "Not enough IMD"; return; }
    go.textContent = s.supply === 0n ? "Make the first mint" : "Mint";
    go.disabled = false;
    lockIfBusy();
  }

  function quoteSell() {
    const s = state;
    const amt = parse($("sellAmt").value);
    $("sellImd").disabled = $("sellKind").disabled = true;
    if (!s) return;
    if (amt < 0n) { $("sellQuote").textContent = "That is not a number."; return; }
    if (amt === 0n) { $("sellQuote").textContent = "Enter an amount."; return; }
    if (s.supply === 0n) { $("sellQuote").textContent = "Nothing is minted yet."; return; }
    const a = amt > s.supply ? s.supply : amt;
    const keep = a === s.supply ? 10000n : 9950n;
    let forImd;
    try {
      const out = X.quoteRedeemToImd(s, a);
      forImd = "about " + fmt(out, 4) + " IMD (at least " + fmt((out * BigInt(10000 - SLIP_BPS)) / 10000n, 4) + ", or nothing happens)";
    } catch (e) {
      forImd = "no quote: " + esc(e.message);
    }
    const kind = s.rows.filter((r) => r.held > 0n).map((r) => fmt((r.held * a * keep) / (s.supply * 10000n), 2) + " " + esc(r.symbol));
    if (s.idle > 0n) kind.push(fmt((s.idle * a * keep) / (s.supply * 10000n), 4) + " IMD");
    $("sellQuote").innerHTML = "For IMD: " + forImd + ".<br>For the coins: " + kind.join(", ") + ".";
    if (!account || amt > s.shares) return;
    $("sellImd").disabled = $("sellKind").disabled = false;
    lockIfBusy();
  }

  async function refresh() {
    try {
      state = await X.load(ethers, reader, account);
      render();
    } catch (e) {
      setStatus("Could not read the chain: " + X.explain(e), "err");
    }
    try {
      const acts = await X.activity(ethers, reader, 12);
      $("acts").innerHTML = acts.length
        ? acts.map((a) => {
            const label = { MintedFirst: "First mint", Minted: "Mint", Redeemed: "Redeem for coins", RedeemedToImd: "Redeem for IMD", Rebalanced: "Rebalance" }[a.name] || a.name;
            const who = a.args[0];
            const sh = a.name === "MintedFirst" ? a.args[2] : a.name === "Rebalanced" ? null : a.args[1];
            const imd = a.name === "MintedFirst" ? a.args[1] : a.name === "Minted" ? a.args[2] : a.name === "RedeemedToImd" ? a.args[2] : null;
            return "<tr><td>" + label + '</td><td><a href="https://etherscan.io/address/' + who + '" target="_blank" rel="noopener">' + short(who) +
              '</a></td><td class="num">' + (sh === null ? "" : fmt(sh, 4)) + '</td><td class="num">' + (imd === null ? "" : fmt(imd, 4)) +
              '</td><td><a href="https://etherscan.io/tx/' + a.tx + '" target="_blank" rel="noopener">' + short(a.tx) + "</a></td></tr>";
          }).join("")
        : '<tr><td colspan="5">No activity yet.</td></tr>';
    } catch (_) {
      $("acts").innerHTML = '<tr><td colspan="5">Activity could not be read from this node.</td></tr>';
    }
  }

  // The chain is read from the wallet on every action, not from ethers' cached network, so a
  // switch after the first action still gets the switch prompt (audit c104e817, L4).
  async function signer() {
    const id = await window.ethereum.request({ method: "eth_chainId" });
    if (BigInt(id) !== X.C.CHAIN_ID) {
      setStatus("Switching your wallet to Ethereum…");
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x1" }] });
      if (BigInt(await window.ethereum.request({ method: "eth_chainId" })) !== X.C.CHAIN_ID) throw new Error("the wallet is not on Ethereum");
    }
    browser = new ethers.BrowserProvider(window.ethereum, "any");
    return browser.getSigner();
  }

  async function run(label, fn, op) {
    if (busy) return;
    busy = true;
    lockIfBusy();
    setStatus(label + "…");
    try {
      const s = await signer();
      const rc = await fn(s, (m) => setStatus(m));
      setStatus(label + " done. Transaction " + short(rc.hash) + ".", "ok");
    } catch (e) {
      setStatus(label + " did not go through: " + X.explain(e, op), "err");
    } finally {
      busy = false;
    }
    await refresh();
  }

  async function connect() {
    if (!window.ethereum) {
      setStatus("No browser wallet found. Install one (for example Rabby or MetaMask), or use a wallet's in-app browser.", "err");
      return;
    }
    try {
      browser = new ethers.BrowserProvider(window.ethereum, "any");
      const accs = await browser.send("eth_requestAccounts", []);
      account = ethers.getAddress(accs[0]);
      $("connect").textContent = short(account);
      window.ethereum.on && window.ethereum.on("chainChanged", () => { browser = new ethers.BrowserProvider(window.ethereum, "any"); refresh(); });
      window.ethereum.on && window.ethereum.on("accountsChanged", (a) => { account = a[0] ? ethers.getAddress(a[0]) : null; $("connect").textContent = account ? short(account) : "Connect wallet"; refresh(); });
      await refresh();
    } catch (e) {
      setStatus("Wallet not connected: " + X.explain(e), "err");
    }
  }

  function wire() {
    $("connect").onclick = connect;
    const themes = ["stone", "white", "slate", "black"];
    try { const t = localStorage.getItem("imdex5-theme"); if (themes.includes(t)) document.documentElement.dataset.theme = t; } catch (_) {}
    $("theme").onclick = () => {
      const t = themes[(themes.indexOf(document.documentElement.dataset.theme) + 1) % themes.length];
      document.documentElement.dataset.theme = t;
      try { localStorage.setItem("imdex5-theme", t); } catch (_) {}
    };
    document.querySelectorAll(".tabs button").forEach((b) => {
      b.onclick = () => {
        document.querySelectorAll(".tabs button").forEach((x) => x.setAttribute("aria-selected", x === b ? "true" : "false"));
        document.querySelectorAll(".pane").forEach((p) => p.classList.toggle("on", p.id === b.dataset.pane));
        setStatus("");
      };
    });
    $("buyAmt").oninput = quoteBuy;
    $("sellAmt").oninput = quoteSell;
    $("buyMax").onclick = () => { if (state && account) { $("buyAmt").value = ethers.formatEther(state.imdBalance); quoteBuy(); } };
    $("sellMax").onclick = () => { if (state && account) { $("sellAmt").value = ethers.formatEther(state.shares); quoteSell(); } };
    $("buyGo").onclick = () => {
      const amt = parse($("buyAmt").value);
      const first = state.supply === 0n;
      run(first ? "First mint" : "Mint", (s, step) => X.mintFor(ethers, s, amt, SLIP_BPS, step), first ? "first" : "mint");
    };
    $("sellImd").onclick = () => {
      const amt = parse($("sellAmt").value);
      run("Redeem for IMD", (s, step) => X.redeemToImdFor(ethers, s, amt, SLIP_BPS, step));
    };
    $("sellKind").onclick = () => {
      const amt = parse($("sellAmt").value);
      run("Redeem for the coins", (s, step) => X.call(ethers, s, "redeem", [amt], step));
    };
    $("owedList").onclick = (ev) => {
      const t = ev.target.closest("[data-claim]");
      if (t) run("Claim", (s, step) => X.call(ethers, s, "claim", [t.dataset.claim], step));
    };
    $("doAsk").onclick = () => run("Ask the oracle", (s, step) => X.call(ethers, s, "ask", [], step));
    $("doRebalance").onclick = () => run("Rebalance", (s, step) => X.call(ethers, s, "rebalance", [], step));
    $("doClose").onclick = () => run("Close the stale question", (s, step) => X.call(ethers, s, "closeRequest", [], step));
  }

  async function main() {
    // never run inside someone else's frame: a framed copy could overlay the buttons
    if (window.top !== window.self) {
      document.body.textContent = "Open this page directly: https://blockmerchantlabs.github.io/imdex5/";
      return;
    }
    wire();
    try {
      reader = await connectReader();
    } catch (e) {
      setStatus("Could not reach an Ethereum node. Refresh to try again.", "err");
      return;
    }
    await refresh();
    setInterval(refresh, 30000);
  }
  main();
})();
