// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Imdex5} from "../src/Imdex5.sol";

/// The patched Imdex5 with the five real coins on a fork of mainnet. One of them (SwarmCity) takes 2% on every buy.
/// forge test --match-contract Fix3ForkTest --fork-url <rpc> -vv
contract Fix3ForkTest is Test {
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    Imdex5 X;
    address alice = address(0xA11CE1);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    function _run(uint256 first) internal {
        // a fork test: without the mainnet contracts (no --fork-url) it is skipped, not failed
        if (IMD.code.length == 0) vm.skip(true);
        X = new Imdex5();
        Imdex5.Coin[] memory cs = X.coins();
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            deal(IMD, who[i], 100_000 ether);
            vm.prank(who[i]);
            IERC20(IMD).approve(address(X), type(uint256).max);
        }
        uint256[] memory minOut = new uint256[](5);
        vm.prank(alice);
        X.mintFirst(first, minOut);
        uint256 aliceShares = X.balanceOf(alice);
        _checkBacked(cs, "after the first mint");

        uint256 b0 = IERC20(IMD).balanceOf(bob);
        vm.prank(bob);
        X.mint(aliceShares / 2, first * 2, aliceShares * 97 / 200);
        uint256 bobShares = X.balanceOf(bob);
        uint256 bobPaid = b0 - IERC20(IMD).balanceOf(bob);
        emit log_named_decimal_uint("Bob asked for shares", aliceShares / 2, 18);
        emit log_named_decimal_uint("Bob was issued shares", bobShares, 18);
        emit log_named_decimal_uint("Bob paid IMD", bobPaid, 18);
        assertLe(bobShares, aliceShares / 2);
        assertApproxEqRel(
            bobShares, aliceShares / 2, 0.021e18, "scaled down by no more than the 2% the taxed coin kept"
        );
        _checkBacked(cs, "after the later mint");

        vm.prank(carol);
        X.mint(aliceShares / 4, first, aliceShares * 97 / 400);
        _checkBacked(cs, "after a third holder");

        // Bob exits to IMD; Carol and Alice redeem in kind. Alice is last.
        vm.prank(bob);
        X.redeemToImd(bobShares, 0);
        uint256 bobBack = IERC20(IMD).balanceOf(bob) - (b0 - bobPaid);
        emit log_named_decimal_uint("Bob got IMD back", bobBack, 18);
        emit log_named_decimal_uint("Bob's round trip cost, percent", (bobPaid - bobBack) * 100 ether / bobPaid, 18);
        _checkBacked(cs, "after an exit to IMD");

        uint256 carolShares = X.balanceOf(carol);
        vm.prank(carol);
        X.redeem(carolShares);
        _checkBacked(cs, "after a redeem in kind");

        vm.prank(alice);
        X.redeem(aliceShares);
        assertEq(X.totalSupply(), 0);
        for (uint256 i; i < 5; ++i) {
            assertGt(IERC20(cs[i].token).balanceOf(alice), 0, "the last holder received every coin");
            assertEq(X.held(cs[i].token), 0);
            assertEq(X.owed(alice, cs[i].token), 0, "nothing was left owed");
            assertEq(IERC20(cs[i].token).balanceOf(address(X)), 0, "nothing is stranded in the contract");
        }
    }

    function _checkBacked(Imdex5.Coin[] memory cs, string memory when) internal {
        for (uint256 i; i < 5; ++i) {
            assertEq(
                IERC20(cs[i].token).balanceOf(address(X)),
                X.held(cs[i].token),
                string.concat("recorded equals real, ", when)
            );
        }
    }

    function test_fixed_with_10_IMD() public {
        _run(10 ether);
    }

    function test_fixed_with_100_IMD() public {
        _run(100 ether);
    }

    function test_fixed_with_1000_IMD() public {
        _run(1_000 ether);
    }
}
