// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20, ReentrantHook} from "./mocks/Mocks.sol";

/// @title Audit 3bd5e1aa (medium): a residual whose buy reverts is never settled at spot
/// @notice A residual (a coin that left the list and could not yet be sold) is bought by `mint`
/// like any holding. When its pool rejects the index's buy outright, the old code charged the
/// minter the residual's fraction at the pool's spot price, which anyone can move first; the mint
/// then issued shares backed by the untouched holding for almost nothing. Now such a buy is a
/// failed buy: `mint` reverts `BuyFailed` and takes nothing. A residual bought short (a transfer
/// tax, liquidity that ran out) is still charged at the price the pool just traded at.
contract Imdex5ResidualSpotTest is Imdex5Base {
    address constant HOOK_M = 0xf0457dD0Cf526686190e4f057Ba19dB14D34a0cc;
    ReentrantHook hookM;

    function setUp() public {
        _deployAll();
        hookM = ReentrantHook(HOOK_M);
        vm.etch(HOOK_M, address(new ReentrantHook()).code);
    }

    /// @dev alice is the only holder; the list drops coin 4, whose limited sale leaves a residual.
    function _residualAfterFirstMint() internal returns (address r) {
        _mintFirst(alice, 1000e18);
        _deliverList(_launches(4));
        vm.prank(bob);
        index.rebalance();
        assertEq(index.listCount(), 4);
        assertEq(index.coins().length, 5);
        r = tokens[4];
        assertGt(index.held(r), 0, "the limited sale should leave a residual");
    }

    /// @dev Moves the residual pool's price down by `factor` without a trade (an attacker's dump).
    function _dump(address r, uint256 factor) internal {
        pm.setPool(_key(r, hooks[4]), 0, 0);
        _setPool(r, hooks[4], COIN_RESERVE * factor, IMD_RESERVE);
    }

    /// The audit's reproduction: dump the residual pool 1,000x, make the index's buy revert, mint
    /// the whole supply. Before the fix bob paid 0.1 IMD for a residual half worth ~49 IMD.
    function test_aDumpedResidualWhoseBuyRevertsCannotBeMintedAtSpot() public {
        address r = _residualAfterFirstMint();
        uint256 heldR = index.held(r);
        uint256 fairValue = heldR * _priceOf(r, hooks[4]) / 1e18;
        assertGt(fairValue, 90e18, "the residual is worth about 98 IMD at the undisturbed price");
        _dump(r, 1000);
        pm.setDead(_key(r, hooks[4]), true);
        uint256 supply = index.totalSupply();
        uint256 idleBefore = index.idleImd();
        _give(bob, 100_000e18);
        uint256 bobImd = imd.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, r));
        index.mint(supply, 100_000e18, 0);
        assertEq(index.balanceOf(bob), 0, "shares issued against a residual nobody bought");
        assertEq(imd.balanceOf(bob), bobImd, "a reverted mint took IMD");
        assertEq(index.totalSupply(), supply);
        assertEq(index.held(r), heldR);
        assertEq(index.idleImd(), idleBefore);
        // alice's claim on the residual is whole: a full redeem pays her all of it
        vm.prank(alice);
        index.redeem(supply);
        assertEq(MockERC20(r).balanceOf(alice), heldR, "the holder's residual was shared with nobody");
        _assertImdAccounting();
    }

    /// Any dump factor, dead pool: the mint reverts and nothing moves.
    function testFuzz_aDeadResidualFailsTheMintAtAnyPrice(uint256 factor, uint256 shares) public {
        factor = bound(factor, 1, 1_000_000);
        address r = _residualAfterFirstMint();
        uint256 supply = index.totalSupply();
        shares = bound(shares, 1, supply * 2);
        _dump(r, factor);
        pm.setDead(_key(r, hooks[4]), true);
        uint256 heldR = index.held(r);
        uint256 bobImd = imd.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, r));
        index.mint(shares, bobImd, 0);
        assertEq(imd.balanceOf(bob), bobImd);
        assertEq(index.held(r), heldR);
        assertEq(index.totalSupply(), supply);
    }

    /// A residual whose hook burns every gas the index's swap is given is a failed buy too.
    function test_aResidualHookThatBurnsGasFailsTheMint() public {
        _mintFirst(alice, 1000e18);
        uint64[] memory list = new uint64[](4);
        list[0] = 1282;
        list[1] = 737;
        list[2] = 1075;
        list[3] = 1175;
        _deliverList(list);
        vm.prank(bob);
        index.rebalance();
        // MARG's limited sale leaves a residual after the list
        assertEq(index.coins()[4].token, tokens[1]);
        uint256 heldM = index.held(tokens[1]);
        hookM.setMisbehave(hookM.MISBEHAVE_BURN(), address(index));
        uint256 bobImd = imd.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, tokens[1]));
        index.mint{gas: 8_000_000}(10e18, 1000e18, 0);
        assertEq(imd.balanceOf(bob), bobImd, "a reverted mint took IMD");
        assertEq(index.held(tokens[1]), heldM);
        // the hook behaves again: the mint buys the residual proportionally
        hookM.setMisbehave(0, address(0));
        uint256 supply = index.totalSupply();
        vm.prank(bob);
        index.mint(10e18, 1000e18, 10e18);
        assertEq(index.held(tokens[1]), heldM + Math.mulDiv(heldM, 10e18, supply, Math.Rounding.Ceil));
    }

    /// A residual whose hook leaves a delta unsettled is a failed buy (`swapSelf` reverts BadDelta).
    function test_aResidualHookThatLeavesADeltaFailsTheMint() public {
        _mintFirst(alice, 1000e18);
        uint64[] memory list = new uint64[](4);
        list[0] = 1282;
        list[1] = 737;
        list[2] = 1075;
        list[3] = 1175;
        _deliverList(list);
        vm.prank(bob);
        index.rebalance();
        assertEq(index.coins()[4].token, tokens[1]);
        hookM.setMisbehave(hookM.MISBEHAVE_TAKE(), address(index));
        uint256 bobImd = imd.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.BuyFailed.selector, tokens[1]));
        index.mint(10e18, 1000e18, 0);
        assertEq(imd.balanceOf(bob), bobImd);
    }

    /// A dumped residual pool that still trades: the mint buys the residual's full fraction, so the
    /// holders keep every coin per share and the minter gains nothing but a cheap buy the pool
    /// itself priced (the dump cost the mover what the buy returns).
    function testFuzz_aDumpedResidualThatTradesIsBoughtInFull(uint256 factor, uint256 shares) public {
        factor = bound(factor, 1, 1000);
        address r = _residualAfterFirstMint();
        uint256 supply = index.totalSupply();
        shares = bound(shares, 1e15, supply);
        _dump(r, factor);
        uint256 heldR = index.held(r);
        uint256 need = Math.mulDiv(heldR, shares, supply, Math.Rounding.Ceil);
        uint256 idleBefore = index.idleImd();
        vm.prank(bob);
        index.mint(shares, 10_000e18, shares);
        assertEq(index.balanceOf(bob), shares);
        assertEq(index.held(r), heldR + need, "the residual's fraction was not bought in full");
        assertEq(MockERC20(r).balanceOf(address(index)), index.held(r), "held differs from the balance");
        // nothing was charged for the residual beyond the buy: idle grew by the issued fraction only
        assertEq(index.idleImd(), idleBefore + Math.mulDiv(idleBefore, shares, supply, Math.Rounding.Ceil));
        // per share, alice holds at least as much of the residual as before
        assertGe(index.held(r) * supply, heldR * index.totalSupply(), "holders diluted in the residual");
        _assertImdAccounting();
    }

    /// A residual pool that fills short still charges the shortfall, at the price it just traded at,
    /// which a buy can only have moved up, never below the fair value of what was not delivered.
    function test_aResidualShortFillIsChargedAtLeastItsFairValue() public {
        address r = _residualAfterFirstMint();
        uint256 price = _priceOf(r, hooks[4]);
        pm.setMaxIn(_key(r, hooks[4]), 1e15);
        uint256 supply = index.totalSupply();
        uint256 heldR = index.held(r);
        uint256 need = Math.mulDiv(heldR, 100e18, supply, Math.Rounding.Ceil);
        uint256 idleBefore = index.idleImd();
        vm.prank(bob);
        index.mint(100e18, 2000e18, 100e18);
        uint256 got = index.held(r) - heldR;
        assertGt(got, 0);
        assertLt(got, need);
        uint256 charged = index.idleImd() - idleBefore - Math.mulDiv(idleBefore, 100e18, supply, Math.Rounding.Ceil);
        assertGe(charged, (need - got) * price / 1e18, "the shortfall was charged under its fair value");
        _assertImdAccounting();
    }
}
