// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Imdex5} from "../src/Imdex5.sol";

/// The minimum-shares floor on a fork of mainnet with the five real coins.
contract Fix3FloorForkTest is Test {
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    Imdex5 X;
    address alice = address(0xA11CE1);
    address bob = address(0xB0B);

    function setUp() public {
        X = new Imdex5();
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 2; ++i) { deal(IMD, who[i], 100_000 ether); vm.prank(who[i]); IERC20(IMD).approve(address(X), type(uint256).max); }
        uint256[] memory minOut = new uint256[](5);
        vm.prank(alice); X.mintFirst(100 ether, minOut);
    }

    /// SwarmCity keeps 2%, so a buy issues about 98% of the shares asked. A floor at 97% passes; a floor at 99% cancels
    /// the whole buy and the buyer keeps every IMD.
    function test_floorPassesAt97_cancelsAt99() public {
        uint256 ask = X.balanceOf(alice) / 2;
        uint256 b0 = IERC20(IMD).balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert();
        X.mint(ask, 200 ether, ask * 99 / 100);
        assertEq(IERC20(IMD).balanceOf(bob), b0, "a cancelled buy costs the buyer nothing");
        assertEq(X.balanceOf(bob), 0);
        vm.prank(bob);
        X.mint(ask, 200 ether, ask * 97 / 100);
        assertGe(X.balanceOf(bob), ask * 97 / 100);
        emit log_named_decimal_uint("asked", ask, 18);
        emit log_named_decimal_uint("issued", X.balanceOf(bob), 18);
    }

    /// A buy so large that a thin pool cannot deliver it: without a floor it would issue a fraction and charge for the
    /// rest; with a floor it cancels.
    function test_oversizedBuy_isCancelledByTheFloor() public {
        uint256 supply = X.totalSupply();
        uint256 ask = supply * 2000;                    // 2,000 times the index, far beyond the pools' depth
        uint256 b0 = IERC20(IMD).balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert();
        X.mint(ask, 100_000 ether, ask * 97 / 100);
        assertEq(IERC20(IMD).balanceOf(bob), b0);
        // The same buy with no floor: what would have happened.
        vm.prank(bob);
        try X.mint(ask, 100_000 ether, 0) {
            emit log_named_decimal_uint("no floor: asked", ask, 18);
            emit log_named_decimal_uint("no floor: issued", X.balanceOf(bob), 18);
            emit log_named_decimal_uint("no floor: paid IMD", b0 - IERC20(IMD).balanceOf(bob), 18);
        } catch { emit log_string("no floor: the buy reverted for another reason (cost above the cap or a failed buy)"); }
    }
}
