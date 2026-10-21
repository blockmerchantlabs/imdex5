# IMDEX5 threat model (READ FIRST)

For auditors. `src/Imdex5.sol` is launch 2343's audited and deployed code (`identity-md-launches/launch-2343-the-imdex-5` at `c100c77`) with the fixes audit 705dd677 asked for: a rebalance or `redeemToImd` swap that takes its input and delivers nothing reverts `NothingOut` inside `swapSelf` and is skipped (medium); a rebalance swap that delivers less than half its input's value at the pool price before it reverts `PoorFill` and is skipped (the same medium, closed against a dust payout); a mint's exact-output residual buy is exempt from both, so its shortfall is charged at the pool price as before; the swap amount is converted with `SafeCast` (low); `mint` refuses `minShares` above `shares` before any buy (low). Launch 2343 itself was launch 1668's code with the 886e7c22 fixes and the 3bd5e1aa fix (a residual whose buy reverts fails the mint instead of being settled at a movable spot price). Everything else is unchanged.

## Actors

| Actor | Can | Trusted to |
|---|---|---|
| Anyone (minter) | `mint` with IMD | nothing; may be a contract, may re-enter through a hook, may front-run |
| Anyone (holder) | `redeem`, `redeemToImd`, transfer shares | nothing |
| Anyone (caller) | `onOracleResult` with the panel's signed answer, then `rebalance` to apply it | nothing beyond submitting a valid signature |
| IMD oracle panel | signs the list of the five largest IMD-paired coins (EIP-712, `IdentityMD Oracle` v2, signer `0x5598…2982`) | at least `MIN_AGREED` = 4 agree on the list |
| Coin pools and hooks (Uniswap v4) | price, liquidity, hooks that can revert, burn gas, re-enter or tax | nothing |
| Coins | may tax on transfer (SwarmCity 2%), return false, revert, burn gas | nothing |

No owner, admin, role, pause or upgrade.

## Invariants (must hold on every path)

1. Every IMD the contract holds is in `feeImd`, `idleImd`, or a running call's accounting; nothing is unaccounted.
2. `held[coin]` equals the coin balance the contract actually holds (what arrived, not what was asked).
3. A mint never issues more shares than the coins it added back per existing share (no dilution of holders); with `minShares > 0` it never issues fewer than `minShares`.
4. A redeem pays each holder their pro-rata share minus the 0.50% fee; the last holder is paid in full, by `redeem` and by `redeemToImd` alike.
5. A failed or short swap never leaves value with the caller that belongs to holders.
6. Only an oracle answer signed by the panel, for this contract, unexpired, with at least four agreeing members in the signed attestation itself, and not replayed, can change the list.

## Deliberately not findings (accepted, documented)

- A coin in the list whose pool dies blocks `mint` until a `rebalance` drops it; `redeem` still works.
- A residual (a coin that left the list and could not yet be sold) is bought by `mint` like any holding. A residual whose pool trades but fills short (a transfer tax, liquidity that ran out) does not block `mint`: the shortfall is paid at the price the pool just traded at into the holders' idle IMD. Holders keep their value; they hold a little less of that coin and a little more IMD. That price is the one the mint's own buy moved to, so it is at or above the price before the buy; moving it first costs the mover what the buy returns. A residual whose pool rejects the index's buy outright (a dead pool, a hook that reverts, burns gas or leaves a delta, a swap that needs more than `SWAP_GAS`) is a failed buy: `mint` reverts `BuyFailed` and takes nothing, as for a dead list coin, until the pool works again or a `rebalance` sells the residual; `redeem` and `redeemToImd` keep working. Settling such a buy at the pool's spot price (audit 3bd5e1aa) let a minter move that price first and take the residual from holders for pool fees and gas.
- A residual pool with no liquidity left in the buy direction: Uniswap v4 fills what it can and leaves the price at the limit, so the shortfall's charge is astronomical and the mint reverts `TooExpensive`. A mint can request at most what the residual's pool can deliver (audit be08f42a, low; documented, not redesigned).
- Residual and idle charges use the requested `shares`; a list coin's short fill reduces `minted` but not the residual fraction bought or charged, so the minter overpays for that fraction by the short fill's ratio and the excess stays with the holders, as any coin bought beyond the issued fraction does (audit 4acb1b2e, low; documented, not redesigned; `minShares` lets the buyer refuse a short fill).
- A rebalance swap, or a `redeemToImd` sale, that takes its input and delivers nothing reverts `NothingOut` inside `swapSelf`, so the caller skips it (audit 705dd677, medium). A rebalance swap must also deliver at least half its input's value at the pool price before it, or it reverts `PoorFill` and is skipped: a hook or tax that keeps more than half is a loss, not a fee. A hook may still keep up to half on a rebalance swap; that is the accepted bound. A mint's exact-output residual buy is exempt from both, so its shortfall is charged as above and mint stays open.
- Small leftovers (rounding, coins bought beyond the issued fraction) stay with existing holders.
- SwarmCity's 2% transfer tax costs a minter about 2% of shares (the floor at 97% passes).
- A round trip (mint then redeem) costs about 3-5% (two 0.50% fees, pool fees, the tax).
- `maxImdIn` caps payment only; `minShares` is the share guarantee.

## Severity scale

Critical: holders' or minters' funds can be taken or frozen by anyone. High: funds lost under realistic conditions or an invariant broken. Medium: loss needs unusual but reachable conditions, or a core function can be blocked by someone else. Low: rounding, gas, clarity. Info: notes.

## Tests

171 unit and fuzz tests against mocks (`forge test`), including the rebalance payout rules (`test/Imdex5RebalanceNothingOut.t.sol`: a rebalance buy or sell that pays nothing is skipped; a buy that pays 1 wei is skipped and one that pays 60% trades), the floor (`test_sliverFillBelowFloorRevertsAndRollsBack`, `test_fullFillPassesFloor`) and the residual attacks (`test/Imdex5ResidualSpot.t.sol`: a dumped residual whose buy reverts cannot be minted at spot, at any price; a residual hook that burns gas or leaves a delta fails the mint; a dumped pool that trades is bought in full and dilutes nobody; a short fill is charged at least its fair value). 8 mainnet fork tests (`test/Fix3*.fork.t.sol`, skipped without `--fork-url`): mint and redeem at 10, 100 and 1,000 IMD; rebalance to three, four and the same five coins; floor passes at 97% and cancels at 99%; an oversized buy is cancelled by the floor.
