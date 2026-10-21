// Regression tests for the site audit c104e817 (2 medium, 6 low, 1 info), run against a mainnet fork:
//   anvil --fork-url <mainnet rpc> --auto-impersonate   then   node site-test/audit-c104e817.js
// Each case starts from the same snapshot (after a 10 IMD first mint) and prints PASS or FAIL.

const path = require("path").join(__dirname, "..", "docs") + "/";
const ethers = require(path + "ethers-6.13.4.umd.min.js");
const X = require(path + "core.js");
const RPC = process.env.FORK_RPC || "http://127.0.0.1:8545";
const D = "0xf2177E53DB73cDAA0BD15D891D3d3378a4098376";
const B = "0x00000000000000000000000000000000000B0B01";
const HOLDER = "0xE54d6571aCa515614927F3A70B8957c2B511603C"; // a large public IMD holder, used only on the fork
const f = (v) => ethers.formatEther(v);
let failed = 0;
const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) failed++; };

// A provider whose reads of INFER's pool state always fail (an RPC that rate-limits one call).
const coder = ethers.AbiCoder.defaultAbiCoder();
const INFER = "0x53d0eA0A685220718Dc6a0a6e4617194C6F37921";
const INFER_SLOT = ethers.keccak256(coder.encode(["bytes32", "uint256"], [
  ethers.keccak256(coder.encode(["address", "address", "uint24", "int24", "address"],
    [INFER, X.C.IMD, 12500, 60, "0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000"])), 6])).slice(2).toLowerCase();
class FlakyProvider extends ethers.JsonRpcProvider {
  constructor(url) { super(url, 1, { staticNetwork: true }); }
  async call(tx) {
    if (tx.to && BigInt(tx.to) === BigInt(X.C.POOL_MANAGER) && String(tx.data).toLowerCase().includes(INFER_SLOT)) throw new Error("429 too many requests");
    return super.call(tx);
  }
}

(async () => {
  const p = new ethers.JsonRpcProvider(RPC, 1, { staticNetwork: true });
  const imd = new ethers.Contract(X.C.IMD, X.ERC20_ABI.concat(["function transfer(address,uint256) returns (bool)"]), p);
  await p.send("anvil_setBalance", [B, "0x56BC75E2D63100000"]);
  await p.send("anvil_setBalance", [HOLDER, "0x56BC75E2D63100000"]);
  await (await imd.connect(new ethers.JsonRpcSigner(p, HOLDER)).transfer(B, ethers.parseEther("2000"))).wait();
  const sd = new ethers.JsonRpcSigner(p, D);
  const sb = new ethers.JsonRpcSigner(p, B);

  // L3: a missing price stops the first mint before any wallet prompt (no approval is sent)
  {
    const flaky = new FlakyProvider(RPC);
    const steps = [];
    let err = null;
    try { await X.mintFor(ethers, new ethers.JsonRpcSigner(flaky, D), ethers.parseEther("10"), 300, (m) => steps.push(m)); } catch (e) { err = e; }
    const allowance = await imd.allowance(D, X.C.INDEX);
    ok(err && /could not be read/.test(err.message) && steps.length === 0 && allowance === 0n, "L3: price read fails -> stopped before approve (" + (err && err.message) + ")");
  }

  await X.mintFor(ethers, sd, ethers.parseEther("10"), 300, () => {});
  const snap = await p.send("evm_snapshot", []);
  const reset = async () => { await p.send("evm_revert", [snap]); return p.send("evm_snapshot", []); };

  // M1: a large mint never signs a floor below the quoted "at least"
  {
    const s = await X.load(ethers, p, B);
    const budget = ethers.parseEther("400");
    const q = X.quoteMint(s, budget, 300);
    const x = new ethers.Contract(X.C.INDEX, ["event Minted(address indexed to, uint256 shares, uint256 imdPaid)"], p);
    let rc = null, err = null;
    try { rc = await X.mintFor(ethers, sb, budget, 300, () => {}); } catch (e) { err = e; }
    if (rc) {
      const ev = rc.logs.map((l) => { try { return x.interface.parseLog(l); } catch (_) { return null; } }).find(Boolean);
      ok(ev && ev.args.shares >= q.minShares, "M1: 400 IMD mint issued " + f(ev.args.shares) + " >= floor " + f(q.minShares));
    } else {
      ok(/minimum shown|cannot fill/.test(X.explain(err, "mint")), "M1: 400 IMD mint refused rather than lowering the floor: " + X.explain(err, "mint"));
    }
  }
  await reset();

  // M2: one failed price read on the wallet's node -> redeem to IMD refuses, nothing is sent
  {
    const sh = (await X.load(ethers, p, D)).shares;
    const flaky = new FlakyProvider(RPC);
    let err = null;
    const before = (await X.load(ethers, p, D)).shares;
    try { await X.redeemToImdFor(ethers, new ethers.JsonRpcSigner(flaky, D), sh / 2n, 300, () => {}); } catch (e) { err = e; }
    const after = (await X.load(ethers, p, D)).shares;
    ok(err && /could not be read/.test(err.message) && after === before, "M2: price read fails -> redeem refused, shares unchanged");
  }
  await reset();

  // L6: a mint too large for the pools reads as a size problem, not "this wallet does not hold enough"
  {
    let err = null;
    try { await X.mintFor(ethers, sb, ethers.parseEther("1900"), 300, () => {}); } catch (e) { err = e; }
    const msg = err ? X.explain(err, "mint") : "minted";
    ok(!/does not hold enough/.test(msg) && /too large|cannot fill/.test(msg), "L6: oversized mint message: " + msg);
  }
  await reset();

  // Point 20a: a mint that cannot go through asks for no approval (simulated as if approved first)
  {
    let err = null;
    try { await X.mintFor(ethers, sb, ethers.parseEther("1900"), 300, () => {}); } catch (e) { err = e; }
    const allowance = await imd.allowance(B, X.C.INDEX);
    ok(err && allowance === 0n, "P20a: impossible mint -> no approval sent (allowance " + f(allowance) + ")");
  }
  await reset();

  // Point 20b: the signed floor is never below what the page showed
  {
    const s = await X.load(ethers, p, B);
    const q = X.quoteMint(s, ethers.parseEther("5"), 300);
    let err = null;
    try { await X.mintFor(ethers, sb, ethers.parseEther("5"), 300, () => {}, { minShares: q.shares * 2n }); } catch (e) { err = e; }
    const allowance = await imd.allowance(B, X.C.INDEX);
    ok(err && allowance === 0n, "P20b: page floor above what can be bought -> refused, no approval: " + (err && X.explain(err, "mint")));
    const sh = (await X.load(ethers, p, D)).shares;
    let err2 = null;
    try { await X.redeemToImdFor(ethers, sd, sh, 300, () => {}, { minImdOut: ethers.parseEther("1000") }); } catch (e) { err2 = e; }
    ok(err2 && (await X.load(ethers, p, D)).shares === sh, "P20b: redeem signs the page's higher minimum -> refused, shares kept");
  }
  await reset();

  // L7: TooLittleOut on a first mint has the first-mint wording
  {
    const e = { revert: { name: "TooLittleOut", args: [1n] } };
    ok(/minimum/.test(X.explain(e, "first")) && !/sale/.test(X.explain(e, "first")), "L7: first-mint TooLittleOut wording");
  }

  // Normal flows still work: a later mint, then redeem to IMD at or above the floor
  {
    const s0 = await X.load(ethers, p, B);
    await X.mintFor(ethers, sb, ethers.parseEther("5"), 300, () => {});
    const s1 = await X.load(ethers, p, B);
    const q = X.quoteRedeemToImd(s1, s1.shares);
    const bal = s1.imdBalance;
    await X.redeemToImdFor(ethers, sb, s1.shares, 300, () => {});
    const s2 = await X.load(ethers, p, B);
    ok(s1.shares > 0n && s2.imdBalance - bal >= (q * 9700n) / 10000n, "flows: mint 5 then redeem to IMD got " + f(s2.imdBalance - bal) + " (quote " + f(q) + ")");
  }

  console.log(failed ? failed + " FAILED" : "all passed");
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error("ERROR", X.explain(e), e); process.exit(1); });
