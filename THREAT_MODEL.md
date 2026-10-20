# IMDEX5 threat model (READ FIRST)

For auditors. `src/Imdex5.sol` is launch 1668's audited and deployed code (`identity-md-launches/launch-1668-the-imdex-5` at `0eada622`) with one change: `mint(shares, maxImdIn, minShares)` reverts `TooFewShares` when fewer than `minShares` shares would be issued. Everything else is unchanged; the diff is about ten lines.

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
- A residual (a coin that left the list and could not yet be sold) never blocks `mint`: the mint buys what its pool gives, and pays whatever the pool cannot give at that pool's current price into the holders' idle IMD. Holders keep their value; they hold a little less of that coin and a little more IMD. The price is the pool's spot price, so a thin residual pool can be moved; the exposure is limited to the residual's share of the index, and moving the price costs the mover.
- Small leftovers (rounding, coins bought beyond the issued fraction) stay with existing holders.
- SwarmCity's 2% transfer tax costs a minter about 2% of shares (the floor at 97% passes).
- A round trip (mint then redeem) costs about 3-5% (two 0.50% fees, pool fees, the tax).
- `maxImdIn` caps payment only; `minShares` is the share guarantee.

## Severity scale

Critical: holders' or minters' funds can be taken or frozen by anyone. High: funds lost under realistic conditions or an invariant broken. Medium: loss needs unusual but reachable conditions, or a core function can be blocked by someone else. Low: rounding, gas, clarity. Info: notes.

## Tests

135 unit and fuzz tests against mocks (`forge test --no-match-path 'test/Fix3*'`), including the floor (`test_sliverFillBelowFloorRevertsAndRollsBack`, `test_fullFillPassesFloor`). 8 mainnet fork tests (`test/Fix3*.fork.t.sol`): mint and redeem at 10, 100 and 1,000 IMD; rebalance to three, four and the same five coins; floor passes at 97% and cancels at 99%; an oversized buy is cancelled by the floor.
