// Runs the site's own transaction code (docs/core.js) against a mainnet fork:
//   anvil --fork-url <mainnet rpc> --auto-impersonate   then   node site-test/fork.js
// First mint (10 IMD, with per-coin minimums), a second wallet's mint, redeem to IMD,
// redeem in kind, the error texts, and the activity feed.

const path = require("path").join(__dirname, "..", "docs") + "/";
const ethers = require(path + "ethers-6.13.4.umd.min.js");
const X = require(path + "core.js");
const p = new ethers.JsonRpcProvider(process.env.FORK_RPC || "http://127.0.0.1:8545", 1, { staticNetwork: true });
const D = "0xf2177E53DB73cDAA0BD15D891D3d3378a4098376";
const B = "0x00000000000000000000000000000000000B0B01";
const f = (v) => ethers.formatEther(v);
function show(s, tag) {
  console.log(`\n== ${tag}: supply ${f(s.supply)} NAV ${f(s.nav)} total ${f(s.total)} idle ${f(s.idle)} fee ${f(s.fee)} canAsk ${s.canAsk}`);
  for (const r of s.rows) console.log(`  ${r.symbol.padEnd(6)} #${r.launch} held ${f(r.held)} price ${f(r.price)} value ${f(r.value)} w ${Number(r.weightBps)/100}% perShare ${f(r.perShare)}`);
}
(async () => {
  const log = (m) => console.log("   step:", m);
  let s = await X.load(ethers, p, D); show(s, "before");
  console.log("delegate IMD", f(s.imdBalance), "shares", f(s.shares));
  const sd = new ethers.JsonRpcSigner(p, D);
  { const s0 = await X.load(ethers, p, D); console.log("minOut", X.firstMintMinOut(s0, ethers.parseEther("10")).map(f).join(" ")); }
  await X.mintFor(ethers, sd, ethers.parseEther("10"), 300, log);
  s = await X.load(ethers, p, D); show(s, "after first mint"); console.log("delegate shares", f(s.shares));
  // second user
  await p.send("anvil_setBalance", [B, "0x56BC75E2D63100000"]);
  const imdHolder = D; // fund B from D
  const imd = new ethers.Contract(X.C.IMD, X.ERC20_ABI.concat(["function transfer(address,uint256) returns (bool)"]), sd);
  await (await imd.transfer(B, ethers.parseEther("5"))).wait();
  const sb = new ethers.JsonRpcSigner(p, B);
  const r = await X.mintFor(ethers, sb, ethers.parseEther("5"), 300, log);
  s = await X.load(ethers, p, B); show(s, "after second mint"); console.log("B shares", f(s.shares), "B IMD left", f(s.imdBalance), "gas", r.gasUsed);
  const q = X.quoteRedeemToImd(s, s.shares); console.log("quote redeemToImd", f(q));
  const before = s.imdBalance;
  await X.redeemToImdFor(ethers, sb, s.shares, 300, log);
  s = await X.load(ethers, p, B); console.log("B got IMD", f(s.imdBalance - before), "vs quote", f(q));
  // delegate redeems half in kind
  s = await X.load(ethers, p, D);
  await X.call(ethers, sd, "redeem", [s.shares / 2n], log);
  s = await X.load(ethers, p, D); show(s, "after half redeem in kind"); console.log("delegate shares", f(s.shares));
  // error path
  try { await X.call(ethers, sd, "rebalance", [], log); } catch (e) { console.log("rebalance ->", X.explain(e)); }
  try { await X.call(ethers, sd, "claim", [X.C.IMD], log); } catch (e) { console.log("claim ->", X.explain(e)); }
  const a = await X.activity(ethers, p, 10);
  for (const e of a) console.log("  activity", e.name, e.block, [...e.args].map(String).join(" "));
})().catch((e) => { console.error("FAIL", X.explain(e), e); process.exit(1); });
