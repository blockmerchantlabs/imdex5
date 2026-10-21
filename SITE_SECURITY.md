# The Imdex 5 site: security model (read first)

For auditors of the website in `docs/` (served as a static page). The contract is out of scope here; it is launch 2361 (`identity-md-launches/launch-2361-the-imdex-5` at `a72ebaac`, deployed at `0xC5a8A9F9B12480B47456E3338695f6038c56e779`), audited separately and documented in `THREAT_MODEL.md`.

## What the site is

A static page with no server, no build step and no third-party requests besides the read nodes.
- `index.html`, `style.css`, `app.js` and `core.js`.
- `ethers-6.13.4.umd.min.js`: a copy of npm `ethers@6.13.4`, byte-identical to `dist/ethers.umd.min.js` in the npm tarball (integrity `sha512-21YtnZVg4/zKkCQPjrDj38B1r4nQvTZLopUGMLQ1ePU2zV/joCfDC3t3iKQjWRzjjjbzR+mdAIoikeBRNkdllA==`; file sha256 `fd66c046…bc61`).
- IBM Plex Mono fonts (SIL OFL 1.1).
- Images: the site's own art, and four coin logos copied from IMD's logo jobs (content hash checked) and from IMD Radar.

`core.js` holds every chain read, quote and transaction. `app.js` only wires the page.

## Trust model

| Thing | Trusted for | If it lies or is compromised |
|---|---|---|
| The visitor's wallet | Signing, and the reads that set a transaction's limits | Out of scope; the wallet shows every call before signing |
| Public read nodes (publicnode, llamarpc, cloudflare) | The figures displayed before connecting | Wrong figures on screen. Transaction limits are recomputed from the wallet's own provider just before signing (`mintFor`, `redeemToImdFor` call `load` on `signer.provider`) |
| Coin symbols and the list | Nothing; they come from whatever tokens the oracle lists | Escaped before they reach `innerHTML` (`esc` in app.js). Addresses, hashes and numbers are the only other dynamic HTML |
| The hosting account | Serving these files unchanged | Full site compromise. The answer is account security (hardware keys, few writers), not page code |

## What each button sends

**Before any wallet prompt**, the exact mint call is simulated as if the IMD approval were already in place: an `eth_call` with a state override of IMD's allowance slot (mapping slot 6), on the wallet's node, or a public node only if the wallet's node lacks overrides. The approval is requested only after that passes. If neither node can simulate, nothing is sent. **The signed minimum** is the higher of the figure the page showed and the figure recomputed from the wallet's node, so it is never below what the user saw. If the price moves between the approval and the mint, the exact approval stays unused, and the mint's own floors still hold.

Every limit is computed once, from one read of the wallet's own node, before any wallet prompt. A coin whose pool price cannot be read stops the action before the wallet opens. Every write runs `staticCall` first, so a call that would revert never reaches the wallet. (Site audit c104e817: all nine findings fixed; regression tests in `site-test/audit-c104e817.js`.)
- **Approve:** exactly the amount being minted, to the index address only. Never an unlimited approval.
- **First mint:** `mintFirst(budget, minOut)`. Each `minOut[i]` is 93% of (budget × 99.5% ÷ n) ÷ the coin's spot price. A coin with no price stops the mint before the wallet opens.
- **Mint:** `mint(shares, maxImdIn = budget, minShares = 97% of shares)`. The quote is budget ÷ (value per share × 1.04). The page and the transaction share one quote (`quoteMint`), and `minShares` is always the "at least" figure the page showed. On `TooExpensive`, or the index running short of IMD mid-buy, the site asks for 1% fewer shares, and stops before the shares would fall below that floor. Unused IMD is refunded by the contract.
- **Redeem for IMD:** `redeemToImd(shares, minImdOut = 97% of the quote)`. The quote assumes a 2.5% cost on each sale.
- **Redeem for the coins / claim / ask / rebalance / closeRequest:** no amounts beyond the user's own input. The upkeep buttons are enabled only when the contract would accept the call.
- **One call at a time:** while one is in flight, every action button is disabled.

- **Max slippage** (1%, 3% default, 5%; kept per browser) sets `minShares` and `minImdOut`. Under 3% warns that it may fail; above 3% warns about larger trades. The first mint's per-coin floor stays at 93%.
- **Price impact:** the page estimates each pool's impact from its active liquidity (`poolDepth`, the IMD side of the virtual reserve) and warns at 3% or more. It is only a warning; the floors above still protect the trade. A failed depth read shows no warning and blocks nothing.
- **Links:** each coin links to Etherscan and to its X account where one is confirmed (a fixed list in `app.js`), otherwise to its IMD explorer page. No link is built from on-chain text.

## Page hardening

- **Content-Security-Policy** (meta): `default-src 'none'`; scripts, styles, fonts and images from the site only; `connect-src` limited to the three read nodes; `base-uri` and `form-action` 'none'. There are no inline scripts and no inline styles.
- **Frame guard:** the page refuses to run inside another site's frame. A meta CSP cannot set `frame-ancestors`, and the host cannot set headers.
- **Referrer:** `no-referrer`.
- **Storage:** only the theme choice is kept, in localStorage.

## Accepted limits (not findings)

- **First mint:** the 7% margin covers the 1.25% pool fee, a transfer tax up to 2% and price impact. A sandwich could take up to that margin from the first mint. The first minter should send through an MEV-protected RPC.
- **Later mints:** they can pay up to about 4% above the displayed value per share and receive down to 97% of the quoted shares. Both bounds are shown before signing.
- **Spot prices:** displayed values use spot pool prices, which anyone can move for a block. Transaction limits bound what such a move can cost.
- **Wallet discovery:** only `window.ethereum` is supported (no EIP-6963 picker).
- **Stuck transactions:** a transaction that never confirms leaves the buttons locked until the page is reloaded.
- **Hosting:** GitHub Pages cannot pin a commit. Whoever can push to the serving branch controls the page.

## Test

`site-test/fork.js` runs `core.js` against a mainnet fork (instructions in the file). It covers:
- a first mint of 10 IMD with the per-coin minimums
- a second wallet's mint
- redeem to IMD (4.627 IMD received against a 4.598 quote)
- redeem in kind
- the error texts
- the activity feed
