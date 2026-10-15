// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Imdex5} from "../src/Imdex5.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20, ReentrantHook} from "./mocks/Mocks.sol";
import {GasBurnerERC20} from "./mocks/AttackMocks.sol";

/// @title The revised paths: dust buys, partial fills, the in-kind redeem rule, the gas caps,
/// hooks that misbehave for the index only, and the oracle's exact boundaries.
contract Imdex5RevisedTest is Imdex5Base {
    function setUp() public {
        _deployAll();
    }

    // ---- mintFirst: a share is never issued for nothing ----
    /// @dev Under 6 wei the equal part is 0 and the pool returns nothing: the whole mint reverts
    /// and the caller keeps every wei. At 6 wei the part is 1 and the mint goes through.
    function test_mintFirstRefusesDustThatBuysNothing() public {
        uint256[] memory minOut = _zeros(5);
        for (uint256 imdIn = 1; imdIn <= 5; ++imdIn) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, tokens[0]));
            index.mintFirst(imdIn, minOut);
        }
        assertEq(index.totalSupply(), 0);
        assertEq(index.feeImd(), 0, "a reverted mint must leave no fee");
        assertEq(imd.balanceOf(alice), 10_000e18);
        vm.prank(alice);
        index.mintFirst(6, minOut);
        assertEq(index.totalSupply(), 5);
        assertEq(index.feeImd(), 1);
        assertEq(index.idleImd(), 0);
        _assertImdAccounting();
    }

    /// @dev A pool that shorts every swap down to nothing is a failed buy, whatever the amount.
    function test_mintFirstRefusesAPoolThatReturnsNothingOnALargeAmount() public {
        pm.setShortBy(_key(tokens[2], hooks[2]), type(uint256).max / 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, tokens[2]));
        index.mintFirst(1000e18, _zeros(5));
        assertEq(index.totalSupply(), 0);
    }

    /// @dev What a pool whose liquidity runs out cannot take stays the holders' idle IMD, the
    /// shares still equal the IMD paid after fee, and the balance equals idle plus fee.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_mintFirstKeepsAPartialFillIdle(uint256 imdIn, uint256 maxIn) public {
        imdIn = bound(imdIn, 1000, 5000e18);
        uint256 fee = (imdIn * 50 + 9999) / 10_000;
        uint256 rest = imdIn - fee;
        uint256 part = rest / 5;
        maxIn = bound(maxIn, 1, part);
        pm.setMaxIn(_key(tokens[3], hooks[3]), maxIn);
        _mintFirst(alice, imdIn);
        assertEq(index.totalSupply(), rest, "shares must equal the IMD paid after fee");
        assertEq(index.idleImd(), rest - part * 4 - maxIn, "the unspent part must be idle");
        assertEq(index.feeImd(), fee);
        assertEq(MockERC20(tokens[3]).balanceOf(address(index)), index.held(tokens[3]));
        assertGt(index.held(tokens[3]), 0);
        _assertImdAccounting();
    }

    /// @dev The partial fill cannot be farmed: the idle IMD it leaves is redeemed pro rata, and
    /// the first minter cannot take out more IMD than went in.
    function test_mintFirstPartialFillIsRedeemedProRataNotTwice() public {
        pm.setMaxIn(_key(tokens[3], hooks[3]), 1e18);
        _mintFirst(alice, 1000e18);
        uint256 idle = index.idleImd();
        assertEq(idle, 199e18 - 1e18);
        vm.prank(alice);
        index.transfer(bob, 495e18);
        vm.prank(alice);
        index.redeem(500e18);
        assertEq(imd.balanceOf(alice), 10_000e18 - 1000e18 + idle * 500e18 * 9950 / (995e18 * 10_000));
        vm.prank(bob);
        index.redeem(495e18);
        assertEq(index.idleImd(), 0);
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob), 20_000e18 - 1000e18 + idle);
        _assertImdAccounting();
    }

    // ---- mint: a hook that misbehaves only for the index is a failed buy, never a free share ----
    function test_mintRevertsWholeWhenTheHookBurnsGasForTheIndex() public {
        _mintFirst(alice, 1000e18);
        hook.setMisbehave(hook.MISBEHAVE_BURN(), address(index));
        vm.prank(bob);
        vm.expectRevert();
        index.mint(10e18, 100e18, 0);
        assertEq(index.balanceOf(bob), 0);
        assertEq(imd.balanceOf(bob), 10_000e18, "a reverted mint must refund everything");
        hook.setMisbehave(0, address(0));
        vm.prank(bob);
        index.mint(10e18, 100e18, 0);
        assertEq(index.balanceOf(bob), 10e18);
        _assertImdAccounting();
    }

    function test_mintRevertsWholeWhenTheHookLeavesADeltaUnsettled() public {
        _mintFirst(alice, 1000e18);
        hook.setMisbehave(hook.MISBEHAVE_TAKE(), address(index));
        uint256 pmImd = imd.balanceOf(address(pm));
        vm.prank(bob);
        vm.expectRevert();
        index.mint(10e18, 100e18, 0);
        assertEq(index.balanceOf(bob), 0);
        assertEq(imd.balanceOf(address(pm)), pmImd, "the hook's take must have been undone");
        assertEq(imd.balanceOf(HOOK_G), 0);
    }

    function test_mintFirstRevertsWholeWhenTheHookMisbehaves() public {
        hook.setMisbehave(hook.MISBEHAVE_BURN(), address(index));
        vm.prank(alice);
        vm.expectRevert();
        index.mintFirst(1000e18, _zeros(5));
        assertEq(index.totalSupply(), 0);
        assertEq(index.feeImd(), 0);
    }

    /// @dev A list coin whose buy was skipped at the last rebalance is held at zero; `mint`
    /// buys exactly `held * f` of it, which is nothing, and the next rebalance buys it.
    function test_mintSkipsAListCoinHeldAtZeroAndTheNextRebalanceBuysIt() public {
        _setPool(tokens[3], hooks[3], COIN_RESERVE * 1000, IMD_RESERVE * 1000);
        _setPool(tokens[4], hooks[4], COIN_RESERVE * 1000, IMD_RESERVE * 1000);
        _mintFirst(alice, 1000e18);
        uint64[] memory list = new uint64[](4);
        list[0] = 1282;
        list[1] = 1283;
        list[2] = 737;
        list[3] = 2000;
        _deliverList(list);
        pm.setDead(_key(NEW_TOKEN, HOOK_G), true);
        vm.prank(bob);
        index.rebalance();
        assertEq(index.held(NEW_TOKEN), 0, "the dead buy must have been skipped");
        uint256 idle = index.idleImd();
        assertGt(idle, 0);
        vm.prank(bob);
        index.mint(100e18, 1000e18, 0);
        assertEq(index.held(NEW_TOKEN), 0, "mint must not buy a coin held at zero");
        assertGt(index.idleImd(), idle, "mint adds the proportional idle IMD");
        pm.setDead(_key(NEW_TOKEN, HOOK_G), false);
        vm.warp(block.timestamp + 7 days);
        _deliverList(list);
        vm.prank(bob);
        index.rebalance();
        assertGt(index.held(NEW_TOKEN), 0, "the next rebalance buys the missing coin");
        _assertImdAccounting();
    }

    // ---- redeemToImd pays an unsellable coin under the redeem rule ----
    /// @dev Both redeem paths pay the same amount of a coin whose pool is dead, and leave the
    /// same residual with the holders.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_redeemToImdPaysADeadCoinExactlyAsRedeemDoes(uint256 shares) public {
        _mintFirst(alice, 1000e18);
        shares = bound(shares, 1, 995e18 - 1);
        pm.setDead(_key(tokens[1], hooks[1]), true);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        index.redeem(shares);
        uint256 inKind = MockERC20(tokens[1]).balanceOf(alice);
        uint256 heldAfterRedeem = index.held(tokens[1]);
        vm.revertToState(snap);
        vm.prank(alice);
        index.redeemToImd(shares, 0);
        // redeemToImd floors twice (the proportional amount, then 99.50% of it): at most 1 wei under
        uint256 paid = MockERC20(tokens[1]).balanceOf(alice);
        assertLe(paid, inKind, "redeemToImd paid a dead coin above what redeem pays");
        assertGe(paid + 1, inKind, "redeemToImd paid a dead coin more than 1 wei under redeem");
        assertEq(index.held(tokens[1]), heldAfterRedeem + (inKind - paid), "the residual differs");
        assertEq(MockERC20(tokens[1]).balanceOf(address(index)), index.held(tokens[1]));
        assertEq(index.totalSupply(), 995e18 - shares);
        _assertImdAccounting();
    }

    function test_lastRedeemerToImdTakesAllOfADeadCoin() public {
        _mintFirst(alice, 1000e18);
        uint256 h = index.held(tokens[1]);
        pm.setDead(_key(tokens[1], hooks[1]), true);
        vm.prank(alice);
        index.redeemToImd(995e18, 0);
        assertEq(index.totalSupply(), 0);
        assertEq(MockERC20(tokens[1]).balanceOf(alice), h, "the last redeemer takes everything");
        assertEq(index.held(tokens[1]), 0);
        assertEq(index.idleImd(), 0);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(index.held(tokens[i]), 0);
        }
        _assertImdAccounting();
    }

    /// @dev A pool whose liquidity runs out sells part; the rest is paid in kind at 99.50% and
    /// the retained 0.50% stays with the holders, so the coin balance still equals `held`.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_redeemToImdPaysAShortFillInKindUnderTheRedeemRule(uint256 shares, uint256 maxIn) public {
        _mintFirst(alice, 1000e18);
        shares = bound(shares, 1e18, 995e18 - 1);
        uint256 amount = index.held(tokens[2]) * shares / 995e18;
        maxIn = bound(maxIn, 1, amount - 1);
        pm.setMaxIn(_key(tokens[2], hooks[2]), maxIn);
        uint256 heldBefore = index.held(tokens[2]);
        vm.prank(alice);
        index.redeemToImd(shares, 0);
        uint256 unsold = amount - maxIn;
        uint256 paid = unsold * 9950 / 10_000;
        assertEq(MockERC20(tokens[2]).balanceOf(alice), paid);
        assertEq(index.held(tokens[2]), heldBefore - maxIn - paid);
        assertEq(MockERC20(tokens[2]).balanceOf(address(index)), index.held(tokens[2]));
        _assertImdAccounting();
    }

    function test_redeemToImdPaysInKindWhenTheHookLeavesADeltaUnsettled() public {
        _mintFirst(alice, 1000e18);
        hook.setMisbehave(hook.MISBEHAVE_TAKE(), address(index));
        uint256 pmImd = imd.balanceOf(address(pm));
        uint256 h0 = index.held(tokens[0]);
        vm.prank(alice);
        index.redeemToImd(199e18, 0);
        // the four coins on hook G are paid in kind; MARG (its own hook, no code) sold
        assertEq(MockERC20(tokens[0]).balanceOf(alice), (h0 * 199e18 / 995e18) * 9950 / 10_000);
        assertEq(MockERC20(tokens[1]).balanceOf(alice), 0);
        assertGt(imd.balanceOf(alice), 10_000e18 - 1000e18);
        assertEq(imd.balanceOf(HOOK_G), 0, "the hook's take was kept");
        assertLt(imd.balanceOf(address(pm)), pmImd, "MARG was not sold");
        _assertImdAccounting();
    }

    // ---- the gas caps ----
    function test_redeemSurvivesFiveGasBurningCoinsWithOrdinaryGas() public {
        _mintFirst(alice, 1000e18);
        uint256[] memory h = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            h[i] = index.held(tokens[i]);
            vm.etch(tokens[i], address(new GasBurnerERC20()).code);
        }
        vm.prank(alice);
        index.redeem{gas: 2_500_000}(500e18);
        assertEq(index.totalSupply(), 495e18);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(index.owed(alice, tokens[i]), h[i] * 500e18 * 9950 / (995e18 * 10_000), "owed");
            assertEq(index.held(tokens[i]), h[i] - index.owed(alice, tokens[i]));
        }
        // restore the coins: every debt is claimable, once
        for (uint256 i = 0; i < 5; ++i) {
            vm.etch(tokens[i], address(new MockERC20()).code);
            uint256 owedNow = index.owed(alice, tokens[i]);
            vm.prank(alice);
            index.claim(tokens[i]);
            assertEq(MockERC20(tokens[i]).balanceOf(alice), owedNow);
            vm.prank(alice);
            vm.expectRevert(Imdex5.NothingOwed.selector);
            index.claim(tokens[i]);
        }
    }

    function test_aCoinThatBurnsItsGasIsOwedAndTheIdleImdStillPaid() public {
        _mintFirst(alice, 1000e18 + 7);
        assertEq(index.idleImd(), 1);
        MockERC20(tokens[0]).setFailMode(3);
        uint256 h0 = index.held(tokens[0]);
        uint256 all = index.balanceOf(alice);
        vm.prank(alice);
        index.redeem{gas: 3_000_000}(all);
        assertEq(index.totalSupply(), 0);
        assertEq(index.owed(alice, tokens[0]), h0);
        assertEq(index.idleImd(), 0);
        assertEq(imd.balanceOf(alice), 10_000e18 - 1000e18 - 7 + 1, "the idle wei after the burner was paid");
        for (uint256 i = 1; i < 5; ++i) {
            assertGt(MockERC20(tokens[i]).balanceOf(alice), 0, "a later coin was starved");
        }
    }

    function test_rebalanceSkipsEveryBurningSwapAndStillAdoptsTheList() public {
        _mintFirst(alice, 1000e18);
        _deliverList(_launches(4));
        hook.setMisbehave(hook.MISBEHAVE_BURN(), address(index));
        uint256 h4 = index.held(tokens[4]);
        uint256 feeBefore = index.feeImd();
        vm.prank(bob);
        index.rebalance{gas: 8_000_000}();
        assertEq(index.listCount(), 4);
        assertEq(index.coins().length, 5, "the unsold leaver stays as a residual");
        assertEq(index.held(tokens[4]), h4, "the burning sale must be skipped whole");
        assertEq(index.nextList().length, 0);
        assertEq(index.feeImd(), feeBefore - 0.25e18, "the caller is still rewarded");
        _assertImdAccounting();
    }

    // ---- reentrancy through the hook into the self-call and the oracle ----
    function test_hookCannotCallSwapSelfOrTheOracleCallbacks() public {
        _mintFirst(alice, 1000e18);
        _deliverList(_launches(4));
        bytes memory swapCall = abi.encodeCall(Imdex5.swapSelf, (tokens[0], hooks[0], false, 1, false, false));
        hook.arm(address(index), swapCall);
        vm.prank(bob);
        index.rebalance();
        assertGt(hook.attempts(), 0);
        assertFalse(hook.reentered(), "the hook called swapSelf");
        assertEq(index.nextList().length, 0);
        _assertImdAccounting();
    }

    function test_hookCannotCloseOrAnswerTheOpenRequestDuringASwap() public {
        _mintFirst(alice, 1000e18);
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
        bytes32 id = intake.lastRequestId();
        hook.arm(address(index), abi.encodeCall(Imdex5.closeRequest, ()));
        vm.warp(block.timestamp + 3 days);
        vm.prank(bob);
        index.mint(1e18, 100e18, 0);
        assertGt(hook.attempts(), 0);
        assertFalse(hook.reentered(), "closeRequest ran inside a swap");
        assertEq(index.openRequest(), id);
        assertGt(index.openSince(), 0);
        OracleAttestation.Attestation memory a = _attestation(_launches(5));
        hook.arm(address(index), abi.encodeCall(Imdex5.onOracleResult, (id, a, "")));
        vm.prank(bob);
        index.mint(1e18, 100e18, 0);
        assertFalse(hook.reentered());
        assertEq(index.answerHash(), bytes32(0), "a hook stored an answer");
    }

    // ---- owed accumulates and is paid once ----
    function test_owedAccumulatesAcrossRedeemsAndIsPaidOnce() public {
        _mintFirst(alice, 1000e18);
        MockERC20(tokens[0]).setFailMode(1);
        vm.prank(alice);
        index.redeem(100e18);
        uint256 first = index.owed(alice, tokens[0]);
        vm.prank(alice);
        index.redeemToImd(100e18, 0);
        uint256 both = index.owed(alice, tokens[0]);
        assertGt(both, first, "the second redeem must add to the debt");
        MockERC20(tokens[0]).setFailMode(0);
        vm.prank(alice);
        index.claim(tokens[0]);
        assertEq(MockERC20(tokens[0]).balanceOf(alice), both);
        assertEq(index.owed(alice, tokens[0]), 0);
        vm.prank(alice);
        vm.expectRevert(Imdex5.NothingOwed.selector);
        index.claim(tokens[0]);
        // bob, who is owed nothing, cannot take alice's debt
        vm.prank(bob);
        vm.expectRevert(Imdex5.NothingOwed.selector);
        index.claim(tokens[0]);
        assertEq(MockERC20(tokens[0]).balanceOf(address(index)), index.held(tokens[0]));
    }

    /// @dev A claim whose transfer fails reverts and keeps the debt: it is never zeroed for nothing.
    function test_claimThatFailsKeepsTheDebt() public {
        _mintFirst(alice, 1000e18);
        MockERC20(tokens[0]).setFailMode(2);
        vm.prank(alice);
        index.redeem(100e18);
        uint256 debt = index.owed(alice, tokens[0]);
        assertGt(debt, 0);
        vm.prank(alice);
        vm.expectRevert();
        index.claim(tokens[0]);
        assertEq(index.owed(alice, tokens[0]), debt);
    }

    // ---- the oracle's exact boundaries ----
    function test_onOracleResultNeedsExactlyFourAgreed() public {
        vm.prank(alice);
        index.fund(1e18);
        vm.prank(bob);
        index.ask();
        bytes32 id = intake.lastRequestId();
        OracleAttestation.Attestation memory a = _attestation(_launches(5));
        a.agreed = 3;
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
        assertEq(index.answerHash(), bytes32(0), "three agreed must not count");
        assertGt(index.openSince(), 0);
        a.agreed = 4;
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
        assertEq(index.answerHash(), keccak256(a.answer));
        assertEq(index.openSince(), 0);
        // the same id again, after the close, is ignored
        a.answer = abi.encode(new bytes32[](0));
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
        assertNotEq(index.answerHash(), keccak256(a.answer), "a second delivery replaced the answer");
    }

    function test_submitTakesAnAttestationOnce() public {
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        _deliver(a);
        bytes memory sig = _sign(a);
        vm.prank(carol);
        index.submit(a, sig);
        assertEq(index.feeImd(), 1e18);
        vm.prank(carol);
        vm.expectRevert(Imdex5.WrongAnswer.selector);
        index.submit(a, sig);
        assertEq(index.feeImd(), 1e18, "a replayed submit must not pay again");
        assertEq(index.nextList().length, 3);
    }

    function test_submitUsesTheRegistryArtifactsNotTheStartingList() public {
        address otherHook = makeAddr("otherHook");
        address otherToken = makeAddr("otherToken");
        // launch 1282 is recorded in B at deployment; A takes precedence when both record it
        regA.record(1282, otherToken, otherHook);
        uint64[] memory list = new uint64[](2);
        list[0] = 1282;
        list[1] = 1283;
        _deliverList(list);
        Imdex5.Coin[] memory next = index.nextList();
        assertEq(next[0].token, otherToken);
        assertEq(next[0].hook, otherHook);
        assertEq(next[1].token, tokens[1]);
        assertEq(next[1].hook, hooks[1]);
    }

    function test_submitRejectsALaunchWithoutAHookOrAToken() public {
        regA.record(3000, makeAddr("tokenOnly"), address(0));
        regB.record(3001, address(0), HOOK_G);
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
        uint64[] memory list = new uint64[](1);
        list[0] = 3000;
        OracleAttestation.Attestation memory a = _attestation(list);
        _deliver(a);
        bytes memory sig = _sign(a);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.ArtifactMissing.selector, uint64(3000)));
        index.submit(a, sig);
        list[0] = 3001;
        vm.warp(block.timestamp + 7 days);
        vm.prank(bob);
        index.ask();
        a = _attestation(list);
        _deliver(a);
        sig = _sign(a);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.ArtifactMissing.selector, uint64(3001)));
        index.submit(a, sig);
        assertEq(index.nextList().length, 0);
    }

    function test_askAndCloseAtTheirExactBoundaries() public {
        vm.prank(alice);
        index.fund(5e18);
        vm.prank(bob);
        index.ask();
        uint256 asked = START; // not block.timestamp: via_ir may hoist that read past a warp
        vm.warp(asked + 2 days - 1);
        vm.prank(carol);
        vm.expectRevert(Imdex5.TooEarly.selector);
        index.closeRequest();
        vm.warp(asked + 2 days);
        vm.prank(carol);
        index.closeRequest();
        vm.warp(asked + 7 days - 1);
        vm.prank(bob);
        vm.expectRevert(Imdex5.AskTooSoon.selector);
        index.ask();
        vm.warp(asked + 7 days);
        vm.prank(bob);
        index.ask();
        assertEq(intake.count(), 2);
        assertEq(index.lastAsk(), asked + 7 days);
    }

    function test_askIsBlockedWhileAListAwaitsRebalance() public {
        _deliverList(_launches(3));
        vm.warp(block.timestamp + 7 days);
        vm.prank(bob);
        vm.expectRevert(Imdex5.ListAwaitsRebalance.selector);
        index.ask();
        _mintFirst(alice, 100e18);
        vm.prank(bob);
        index.rebalance();
        vm.prank(bob);
        index.ask();
        assertEq(intake.count(), 2);
    }

    // ---- the hook address of the starting list is per launch, not one hook for all ----
    function test_margUsesItsOwnHookAndTheOthersShareG() public view {
        Imdex5.Coin[] memory coins = index.coins();
        assertEq(coins[1].hook, 0xf0457dD0Cf526686190e4f057Ba19dB14D34a0cc);
        for (uint256 i = 0; i < 5; ++i) {
            if (i != 1) assertEq(coins[i].hook, HOOK_G);
        }
        assertEq(ReentrantHook(HOOK_G).attempts(), 0);
    }
}
