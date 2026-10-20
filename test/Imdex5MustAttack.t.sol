// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {TaxERC20} from "./mocks/TaxERC20.sol";

/// @title The brief's MUST ATTACK list, one section per item
/// @notice (1) a mint that succeeds under `minShares`; (2) a reverted mint that keeps IMD; (3) `held`
/// differing from the real balance; (4) a mint that dilutes holders in value, including through a
/// residual's price moved first; (5) a redeem that cannot pay; (6) an expired or under-quorum
/// answer changing the list.
contract Imdex5MustAttackTest is Imdex5Base {
    struct Snap {
        uint256 callerImd;
        uint256 callerShares;
        uint256 indexImd;
        uint256 supply;
        uint256 idle;
        uint256 fee;
        uint256[] held;
    }

    function setUp() public {
        _deployAll();
    }

    // ---- helpers ----
    function _snap(address who) internal view returns (Snap memory s) {
        s.callerImd = imd.balanceOf(who);
        s.callerShares = index.balanceOf(who);
        s.indexImd = imd.balanceOf(address(index));
        s.supply = index.totalSupply();
        s.idle = index.idleImd();
        s.fee = index.feeImd();
        s.held = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            s.held[i] = index.held(tokens[i]);
        }
    }

    function _assertUnchanged(Snap memory a, address who) internal view {
        Snap memory b = _snap(who);
        assertEq(b.callerImd, a.callerImd, "a reverted mint took the caller's IMD");
        assertEq(b.callerShares, a.callerShares, "a reverted mint issued shares");
        assertEq(b.indexImd, a.indexImd, "a reverted mint moved the index's IMD");
        assertEq(b.supply, a.supply, "supply changed");
        assertEq(b.idle, a.idle, "idle changed");
        assertEq(b.fee, a.fee, "fee changed");
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(b.held[i], a.held[i], "held changed");
        }
    }

    function _assertHeldIsBalance() internal view {
        for (uint256 i; i < tokens.length; ++i) {
            uint256 owedSum = index.owed(alice, tokens[i]) + index.owed(bob, tokens[i]) + index.owed(carol, tokens[i]);
            assertEq(
                MockERC20(tokens[i]).balanceOf(address(index)),
                index.held(tokens[i]) + owedSum,
                "held != balance - owed"
            );
        }
        uint256 owedImd =
            index.owed(alice, address(imd)) + index.owed(bob, address(imd)) + index.owed(carol, address(imd));
        assertEq(imd.balanceOf(address(index)), index.idleImd() + index.feeImd() + owedImd, "IMD unaccounted");
    }

    /// @dev Value of the index at fixed prices (in IMD scaled by 1e18, unrounded), so a price
    /// move does not count as dilution.
    function _valueAt(uint256[] memory prices) internal view returns (uint256 v) {
        v = index.idleImd() * 1e18;
        for (uint256 i; i < tokens.length; ++i) {
            v += index.held(tokens[i]) * prices[i];
        }
    }

    function _prices() internal view returns (uint256[] memory p) {
        p = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            p[i] = _priceOf(tokens[i], hooks[i]);
        }
    }

    /// @dev alice is the only holder; the list drops coin 4, whose limited sale leaves a residual.
    function _residual() internal returns (address r) {
        _mintFirst(alice, 1000e18);
        _deliverList(_launches(4));
        vm.prank(bob);
        index.rebalance();
        r = tokens[4];
        assertEq(index.listCount(), 4);
        assertEq(index.coins()[4].token, r);
        assertGt(index.held(r), 0);
    }

    // =====================================================================================
    // (1) never fewer than minShares
    // =====================================================================================

    /// A list coin that fills short: whatever the floor, the mint either issues at least
    /// `minShares` (and at most `shares`) or reverts whole.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_mintNeverIssuesBelowTheFloor(uint256 coin, uint256 maxIn, uint256 shares, uint256 minShares)
        public
    {
        _mintFirst(alice, 1000e18);
        coin = bound(coin, 0, 4);
        maxIn = bound(maxIn, 1, 1000e18);
        pm.setMaxIn(_key(tokens[coin], hooks[coin]), maxIn);
        uint256 supply = index.totalSupply();
        shares = bound(shares, 1, supply * 2);
        minShares = bound(minShares, 0, shares + 1);
        Snap memory s = _snap(bob);
        vm.prank(bob);
        try index.mint(shares, 10_000e18, minShares) {
            uint256 minted = index.balanceOf(bob);
            assertGe(minted, minShares, "issued below the floor");
            assertLe(minted, shares, "issued above the request");
            assertGt(minted, 0);
            _assertHeldIsBalance();
        } catch {
            _assertUnchanged(s, bob);
        }
    }

    /// The exact boundary: a short fill issuing m shares passes with minShares = m and reverts
    /// TooFewShares(m) with minShares = m + 1, leaving every balance as it was.
    function test_floorBoundaryIsExact() public {
        _mintFirst(alice, 1000e18);
        pm.setMaxIn(_key(tokens[2], hooks[2]), 10e18);
        uint256 snapId = vm.snapshotState();
        vm.prank(bob);
        index.mint(500e18, 10_000e18, 0);
        uint256 m = index.balanceOf(bob);
        assertGt(m, 0);
        assertLt(m, 500e18, "the cap should cut the mint");
        vm.revertToState(snapId);

        Snap memory s = _snap(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.TooFewShares.selector, m));
        index.mint(500e18, 10_000e18, m + 1);
        _assertUnchanged(s, bob);

        vm.prank(bob);
        index.mint(500e18, 10_000e18, m);
        assertEq(index.balanceOf(bob), m);
    }

    /// minShares above shares can never be met: TooFewShares(shares), nothing taken.
    function test_floorAboveRequestAlwaysReverts() public {
        _mintFirst(alice, 1000e18);
        Snap memory s = _snap(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.TooFewShares.selector, 10e18));
        index.mint(10e18, 10_000e18, 10e18 + 1);
        _assertUnchanged(s, bob);
    }

    /// A residual's short fill never reduces `minted`: with the floor at `shares`, the mint passes
    /// and issues exactly `shares` even though the residual delivered nothing.
    function test_residualShortFillDoesNotCutSharesBelowFloor() public {
        address r = _residual();
        vm.etch(r, address(new TaxERC20(address(pm))).code);
        TaxERC20(r).setTax(5000, false);
        vm.prank(bob);
        index.mint(100e18, 10_000e18, 100e18);
        assertEq(index.balanceOf(bob), 100e18);
        _assertHeldIsBalance();
    }

    // =====================================================================================
    // (2) a reverted mint never keeps IMD
    // =====================================================================================

    function test_revertedMintsTakeNothing_everyPath() public {
        // FirstMintOnly
        Snap memory s = _snap(bob);
        vm.prank(bob);
        vm.expectRevert(Imdex5.FirstMintOnly.selector);
        index.mint(1e18, 100e18, 0);
        _assertUnchanged(s, bob);

        _mintFirst(alice, 1000e18);

        // ZeroAmount
        s = _snap(bob);
        vm.prank(bob);
        vm.expectRevert(Imdex5.ZeroAmount.selector);
        index.mint(0, 100e18, 0);
        _assertUnchanged(s, bob);

        // maxImdIn far below the cost: the pool payment itself cannot be covered and reverts
        s = _snap(bob);
        vm.prank(bob);
        vm.expectRevert();
        index.mint(100e18, 1e18, 0);
        _assertUnchanged(s, bob);

        // TooExpensive: maxImdIn one wei below the cost
        uint256 snapId = vm.snapshotState();
        vm.prank(bob);
        index.mint(10e18, 10_000e18, 0);
        uint256 cost = s.callerImd - imd.balanceOf(bob);
        vm.revertToState(snapId);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.TooExpensive.selector, cost));
        index.mint(10e18, cost - 1, 0);
        _assertUnchanged(s, bob);

        // maxImdIn of zero
        s = _snap(bob);
        vm.prank(bob);
        vm.expectPartialRevert(Imdex5.TooExpensive.selector);
        index.mint(1, 0, 0);
        _assertUnchanged(s, bob);

        // TooFewShares
        pm.setMaxIn(_key(tokens[0], hooks[0]), 1e18);
        s = _snap(bob);
        vm.prank(bob);
        vm.expectPartialRevert(Imdex5.TooFewShares.selector);
        index.mint(100e18, 10_000e18, 100e18);
        _assertUnchanged(s, bob);
        pm.setMaxIn(_key(tokens[0], hooks[0]), 0);

        // a list pool that is dead
        pm.setDead(_key(tokens[3], hooks[3]), true);
        s = _snap(bob);
        vm.prank(bob);
        vm.expectRevert();
        index.mint(10e18, 10_000e18, 0);
        _assertUnchanged(s, bob);
        pm.setDead(_key(tokens[3], hooks[3]), false);

        // a list coin that keeps everything it sends: delivered fraction rounds to zero
        vm.etch(tokens[1], address(new TaxERC20(address(pm))).code);
        TaxERC20(tokens[1]).setTax(10_000, false);
        s = _snap(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, tokens[1]));
        index.mint(10e18, 10_000e18, 0);
        _assertUnchanged(s, bob);
        TaxERC20(tokens[1]).setTax(0, false);

        // the caller cannot pay maxImdIn
        s = _snap(bob);
        vm.prank(bob);
        vm.expectRevert();
        index.mint(10e18, s.callerImd + 1, 0);
        _assertUnchanged(s, bob);

        // after every failure the mint still works and the accounting is whole
        vm.prank(bob);
        index.mint(10e18, 10_000e18, 10e18);
        assertEq(index.balanceOf(bob), 10e18);
        _assertHeldIsBalance();
    }

    /// A successful mint keeps exactly `total` and refunds the rest of `maxImdIn`; the IMD kept
    /// equals the growth of idle plus fee plus what went to the pools.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_mintKeepsOnlyWhatItSpends(uint256 shares, uint256 slack) public {
        _mintFirst(alice, 1000e18);
        shares = bound(shares, 1, 2000e18);
        slack = bound(slack, 0, 5000e18);
        uint256 pmBefore = imd.balanceOf(address(pm));
        Snap memory s = _snap(bob);
        // learn the cost, then pay it plus slack
        uint256 snapId = vm.snapshotState();
        vm.prank(bob);
        index.mint(shares, 10_000e18, 0);
        uint256 cost = s.callerImd - imd.balanceOf(bob);
        vm.revertToState(snapId);
        if (cost + slack > s.callerImd) slack = s.callerImd - cost;
        vm.prank(bob);
        index.mint(shares, cost + slack, shares);
        uint256 paid = s.callerImd - imd.balanceOf(bob);
        assertEq(paid, cost, "slack was not refunded");
        uint256 toPools = imd.balanceOf(address(pm)) - pmBefore;
        assertEq(paid, toPools + (index.idleImd() - s.idle) + (index.feeImd() - s.fee), "paid IMD is not all accounted");
        _assertHeldIsBalance();
    }

    // =====================================================================================
    // (3) held equals the real balance
    // =====================================================================================

    /// Every path that moves coins, with every coin taxed out of the pool at a fuzzed rate and
    /// a donation on top: balance == held + owed after each step.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_heldTracksBalanceThroughEveryPath(uint16 taxBps, uint256 donation) public {
        taxBps = uint16(bound(taxBps, 0, 900));
        donation = bound(donation, 0, 1e21);
        for (uint256 i; i < 5; ++i) {
            vm.etch(tokens[i], address(new TaxERC20(address(pm))).code);
            TaxERC20(tokens[i]).setTax(taxBps, false);
        }
        _mintFirst(alice, 1000e18);
        _assertHeldIsBalance();
        MockERC20(tokens[0]).mint(address(index), donation);
        uint256 extra0 = donation;
        vm.prank(bob);
        index.mint(50e18, 10_000e18, 0);
        assertEq(MockERC20(tokens[0]).balanceOf(address(index)), index.held(tokens[0]) + extra0);
        vm.prank(alice);
        index.redeem(100e18);
        assertEq(MockERC20(tokens[0]).balanceOf(address(index)), index.held(tokens[0]) + extra0);
        vm.prank(alice);
        index.redeemToImd(100e18, 0);
        assertEq(MockERC20(tokens[0]).balanceOf(address(index)), index.held(tokens[0]) + extra0);
        _deliverList(_launches(3));
        vm.prank(carol);
        index.rebalance();
        assertEq(MockERC20(tokens[0]).balanceOf(address(index)), index.held(tokens[0]) + extra0);
        for (uint256 i = 1; i < 5; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), index.held(tokens[i]), "held != balance");
        }
        assertEq(imd.balanceOf(address(index)), index.idleImd() + index.feeImd());
    }

    /// A coin whose payment fails is owed, not lost: held drops, the balance stays, the claim
    /// later closes the gap exactly.
    function test_owedCoinsAreTheOnlyGapBetweenHeldAndBalance() public {
        _mintFirst(alice, 1000e18);
        MockERC20(tokens[2]).setFailMode(2);
        vm.prank(alice);
        index.redeem(100e18);
        uint256 o = index.owed(alice, tokens[2]);
        assertGt(o, 0);
        _assertHeldIsBalance();
        MockERC20(tokens[2]).setFailMode(0);
        vm.prank(alice);
        index.claim(tokens[2]);
        assertEq(MockERC20(tokens[2]).balanceOf(address(index)), index.held(tokens[2]));
        assertEq(MockERC20(tokens[2]).balanceOf(alice), o);
    }

    // =====================================================================================
    // (4) no dilution in value
    // =====================================================================================

    /// At undisturbed pools, any mint (full or short fill) leaves every holding and the idle IMD
    /// per share at least where they were, so value per share at the pre-mint prices never falls.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_mintNeverDilutesPerShare(uint256 shares, uint256 coin, uint256 maxIn) public {
        _mintFirst(alice, 1000e18);
        vm.prank(carol);
        index.mint(37e18, 10_000e18, 0);
        coin = bound(coin, 0, 5);
        if (coin < 5) pm.setMaxIn(_key(tokens[coin], hooks[coin]), bound(maxIn, 1, 100e18));
        uint256[] memory prices = _prices();
        uint256 supply = index.totalSupply();
        shares = bound(shares, 1, supply * 3);
        Snap memory s = _snap(bob);
        uint256 v0 = _valueAt(prices);
        vm.prank(bob);
        try index.mint(shares, 10_000e18, 0) {
            uint256 supply1 = index.totalSupply();
            for (uint256 i; i < 5; ++i) {
                assertGe(index.held(tokens[i]) * s.supply, s.held[i] * supply1, "a holding per share fell");
            }
            assertGe(index.idleImd() * s.supply, s.idle * supply1, "idle per share fell");
            assertGe(_valueAt(prices) * s.supply, v0 * supply1, "value per share fell");
        } catch {
            _assertUnchanged(s, bob);
        }
    }

    /// Tiny mints round up every coin they owe: one share of a large supply still buys at least
    /// one wei of each held coin, never a free share.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_dustMintsRoundAgainstTheMinter(uint256 shares) public {
        _mintFirst(alice, 5000e18);
        shares = bound(shares, 1, 1e6);
        Snap memory s = _snap(bob);
        vm.prank(bob);
        index.mint(shares, 10_000e18, 0);
        assertLt(imd.balanceOf(bob), s.callerImd, "a dust mint was free");
        for (uint256 i; i < 5; ++i) {
            assertGe(index.held(tokens[i]) - s.held[i], 1, "a coin was not bought");
            assertGe(index.held(tokens[i]) * s.supply, s.held[i] * index.totalSupply());
        }
    }

    /// A residual's pool price moved down before the mint, residual delivering in full: the
    /// holders keep every residual coin per share; the dump only made the buy cheaper.
    /// forge-config: default.fuzz.runs = 100
    function testFuzz_residualDumpedThenBoughtInFullDilutesNobodyInCoins(uint256 factor, uint256 shares) public {
        address r = _residual();
        factor = bound(factor, 1, 1000);
        uint256 supply = index.totalSupply();
        shares = bound(shares, 1e12, supply);
        pm.setPool(_key(r, hooks[4]), 0, 0);
        _setPool(r, hooks[4], COIN_RESERVE * factor, IMD_RESERVE);
        Snap memory s = _snap(bob);
        vm.prank(bob);
        index.mint(shares, 10_000e18, shares);
        uint256 supply1 = index.totalSupply();
        for (uint256 i; i < 5; ++i) {
            assertGe(index.held(tokens[i]) * s.supply, s.held[i] * supply1, "diluted in a coin");
        }
        _assertHeldIsBalance();
    }

    /// A residual that fills short at an undisturbed pool: the shortfall is charged at the
    /// post-buy price, at or above the pre-mint price, so value per share at pre-mint prices
    /// does not fall whatever the tax.
    /// forge-config: default.fuzz.runs = 100
    function testFuzz_residualShortFillAtUndisturbedPriceDilutesNobody(uint16 taxBps, uint256 shares) public {
        address r = _residual();
        vm.etch(r, address(new TaxERC20(address(pm))).code);
        TaxERC20(r).setTax(bound(taxBps, 1, 10_000), false);
        uint256[] memory prices = _prices();
        uint256 supply = index.totalSupply();
        shares = bound(shares, 1e15, supply);
        uint256 v0 = _valueAt(prices);
        vm.prank(bob);
        index.mint(shares, 10_000e18, shares);
        assertGe(_valueAt(prices) * supply, v0 * index.totalSupply(), "value per share fell");
        _assertHeldIsBalance();
    }

    // =====================================================================================
    // (5) a redeem always pays
    // =====================================================================================

    /// Every coin failing in a different way, every pool dead: `redeem` still burns and pays or
    /// records each coin, and the last holder takes everything.
    function test_redeemPaysWhenEveryCoinAndPoolMisbehaves() public {
        _mintFirst(alice, 1000e18);
        vm.prank(bob);
        index.mint(100e18, 10_000e18, 0);
        MockERC20(tokens[0]).setFailMode(1);
        MockERC20(tokens[1]).setFailMode(2);
        MockERC20(tokens[2]).setFailMode(3);
        for (uint256 i; i < 5; ++i) {
            pm.setDead(_key(tokens[i], hooks[i]), true);
        }
        uint256 bobShares = index.balanceOf(bob);
        vm.prank(bob);
        index.redeemToImd(bobShares, 0);
        assertEq(index.balanceOf(bob), 0);
        _assertHeldIsBalance();
        uint256 aliceShares = index.balanceOf(alice);
        vm.prank(alice);
        index.redeem(aliceShares);
        assertEq(index.totalSupply(), 0);
        for (uint256 i; i < 5; ++i) {
            assertEq(index.held(tokens[i]), 0, "the last holder left a coin behind");
        }
        assertEq(index.idleImd(), 0);
        assertGt(index.owed(alice, tokens[0]), 0);
        assertGt(index.owed(alice, tokens[1]), 0);
        assertGt(index.owed(alice, tokens[2]), 0);
        assertGt(MockERC20(tokens[3]).balanceOf(alice), 0);
        _assertHeldIsBalance();
    }

    /// Redeem of any amount by any of two holders, in either form, always succeeds and never pays
    /// more than the pro-rata share; the last holder pays no fee on either path.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_redeemAlwaysPaysProRata(uint256 shares, bool toImd) public {
        _mintFirst(alice, 1000e18);
        vm.prank(bob);
        index.mint(200e18, 10_000e18, 0);
        uint256 bal = index.balanceOf(alice);
        shares = bound(shares, 1, bal);
        Snap memory s = _snap(alice);
        vm.prank(alice);
        if (toImd) index.redeemToImd(shares, 0);
        else index.redeem(shares);
        assertEq(index.balanceOf(alice), bal - shares);
        if (!toImd) {
            for (uint256 i; i < 5; ++i) {
                uint256 got = MockERC20(tokens[i]).balanceOf(alice);
                assertLe(got, Math.mulDiv(s.held[i], shares, s.supply), "paid more than pro rata");
                assertGe(got, Math.mulDiv(s.held[i], shares * 9950, s.supply * 10_000));
            }
        }
        _assertHeldIsBalance();
        // bob is now the last holder and leaves with no fee on redeemToImd
        uint256 bobShares = index.balanceOf(bob);
        uint256 feeBefore = index.feeImd();
        vm.prank(bob);
        index.redeemToImd(bobShares, 0);
        if (index.totalSupply() == 0) assertEq(index.feeImd(), feeBefore, "the last holder paid a fee");
    }

    // =====================================================================================
    // (6) only a current, quorate, signed answer changes the list
    // =====================================================================================

    function _askAndDeliver(OracleAttestation.Attestation memory a) internal {
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
        _deliver(a);
    }

    function test_expiredAnswerNeverChangesTheList() public {
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        _askAndDeliver(a);
        bytes memory sig = _sign(a);
        vm.warp(a.expiresAt + 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        index.submit(a, sig);
        assertEq(index.nextList().length, 0);
        // exactly at expiry is still valid
        vm.warp(a.expiresAt);
        vm.prank(carol);
        index.submit(a, sig);
        assertEq(index.nextList().length, 3);
    }

    function test_futureIssuedAnswerIsRefused() public {
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        a.issuedAt = uint64(block.timestamp + 5 minutes + 1);
        a.expiresAt = a.issuedAt + 86_400;
        _askAndDeliver(a);
        bytes memory sig = _sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        index.submit(a, sig);
        assertEq(index.nextList().length, 0);
    }

    /// The callback saw a quorate copy; the signed attestation presented says three agreed.
    function test_underQuorumSignedAnswerNeverChangesTheList() public {
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        _askAndDeliver(a);
        a.agreed = 3;
        bytes memory sig = _sign(a);
        vm.expectRevert(Imdex5.BadList.selector);
        index.submit(a, sig);
        assertEq(index.nextList().length, 0);
    }

    /// A thin panel delivered through the Intake is not even stored.
    /// forge-config: default.fuzz.runs = 50
    function testFuzz_underQuorumDeliveryIsIgnored(uint16 agreed) public {
        agreed = uint16(bound(agreed, 0, 3));
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        a.agreed = agreed;
        _askAndDeliver(a);
        assertEq(index.answerHash(), bytes32(0));
        assertGt(index.openSince(), 0, "a thin panel closed the request");
        bytes memory sig = _sign(a);
        vm.expectRevert(Imdex5.WrongAnswer.selector);
        index.submit(a, sig);
    }

    function test_wrongSignerAndReplayAreRefused() public {
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        _askAndDeliver(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, index.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        index.submit(a, abi.encodePacked(r, s, v));
        bytes memory sig = _sign(a);
        index.submit(a, sig);
        vm.expectRevert(Imdex5.WrongAnswer.selector);
        index.submit(a, sig);
    }

    /// A different answer than the one the Intake delivered, even validly signed, is refused.
    function test_answerOtherThanDeliveredIsRefused() public {
        _askAndDeliver(_attestation(_launches(3)));
        OracleAttestation.Attestation memory other = _attestation(_launches(4));
        bytes memory sig = _sign(other);
        vm.expectRevert(Imdex5.WrongAnswer.selector);
        index.submit(other, sig);
    }

    /// Only the Intake's callback for the open request stores an answer.
    function test_callbackFromAnyoneElseIsIgnored() public {
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        bytes32 id = intake.lastRequestId();
        vm.prank(carol);
        index.onOracleResult(id, a, "");
        assertEq(index.answerHash(), bytes32(0));
        vm.prank(address(intake));
        index.onOracleResult(keccak256("other"), a, "");
        assertEq(index.answerHash(), bytes32(0));
    }
}
