// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @dev Audit 705dd677, medium 1: a rebalance swap that takes its input and delivers nothing is
/// skipped, not booked. Without the `NothingOut` check in `swapSelf`, the buy spent idle IMD for no
/// coins and the sell took coins for no IMD, with the accounting still balanced.
contract Imdex5RebalanceNothingOutTest is Imdex5Base {
    function setUp() public {
        _deployAll();
    }

    function _replaceFifthWithNew() internal returns (uint64[] memory list) {
        list = _launches(5);
        list[4] = 2000; // NEW_TOKEN on HOOK_G
        _deliverList(list);
    }

    function _skipped(Vm.Log[] memory logs, address coin, bool buy) internal pure returns (bool) {
        bytes32 sig = keccak256("SwapSkipped(address,bool,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || address(uint160(uint256(logs[i].topics[1]))) != coin) continue;
            (bool b,) = abi.decode(logs[i].data, (bool, uint256));
            if (b == buy) return true;
        }
        return false;
    }

    function test_aRebalanceBuyThatDeliversNothingIsSkipped() public {
        _mintFirst(alice, 1000e18);
        _replaceFifthWithNew();
        pm.setShortBy(_key(NEW_TOKEN, HOOK_G), type(uint128).max);
        uint256 poolImdBefore = imd.balanceOf(address(pm));
        vm.recordLogs();
        vm.prank(bob);
        index.rebalance();
        assertTrue(_skipped(vm.getRecordedLogs(), NEW_TOKEN, true), "the buy was not skipped");
        assertEq(index.held(NEW_TOKEN), 0);
        // the leaver's sale paid IMD in; nothing of it went to the pool that delivers nothing
        assertEq(imd.balanceOf(address(index)), index.idleImd() + index.feeImd(), "imd balance != idle + fee");
        assertLe(imd.balanceOf(address(pm)), poolImdBefore, "idle IMD went to a pool for no coins");
    }

    function test_aRebalanceSellThatPaysNothingIsSkipped() public {
        _mintFirst(alice, 1000e18);
        address leaver = tokens[4];
        Imdex5.Coin[] memory coins = index.coins();
        uint256 heldBefore = index.held(leaver);
        uint256 idleBefore = index.idleImd();
        _replaceFifthWithNew();
        pm.setShortBy(_key(leaver, coins[4].hook), type(uint128).max);
        vm.recordLogs();
        vm.prank(bob);
        index.rebalance();
        assertTrue(_skipped(vm.getRecordedLogs(), leaver, false), "the sell was not skipped");
        assertEq(index.held(leaver), heldBefore, "coins were sold for no IMD");
        assertEq(MockERC20(leaver).balanceOf(address(index)), heldBefore);
        assertLe(index.idleImd(), idleBefore, "idle grew without a sale");
        assertEq(imd.balanceOf(address(index)), index.idleImd() + index.feeImd(), "imd balance != idle + fee");
    }

    function _boughtOut(Vm.Log[] memory logs, address coin) internal pure returns (uint256) {
        bytes32 sig = keccak256("Swapped(address,bool,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || address(uint160(uint256(logs[i].topics[1]))) != coin) continue;
            (bool b,, uint256 out) = abi.decode(logs[i].data, (bool, uint256, uint256));
            if (b) return out;
        }
        return 0;
    }

    /// @dev In-house review of 646635a: a pool that pays 1 wei passed `NothingOut`. The
    /// 50% floor (`PoorFill`) skips it; a pool that keeps 40% still trades.
    function test_aRebalanceBuyThatPaysDustIsSkippedAndAFairOneTrades() public {
        _mintFirst(alice, 1000e18);
        _replaceFifthWithNew();
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(bob);
        index.rebalance();
        uint256 gross = _boughtOut(vm.getRecordedLogs(), NEW_TOKEN);
        assertGt(gross, 2, "the honest buy did not run");
        vm.revertToState(snap);

        snap = vm.snapshotState();
        pm.setShortBy(_key(NEW_TOKEN, HOOK_G), gross - 1); // pays 1 wei
        vm.recordLogs();
        vm.prank(bob);
        index.rebalance();
        assertTrue(_skipped(vm.getRecordedLogs(), NEW_TOKEN, true), "a dust buy was booked");
        assertEq(index.held(NEW_TOKEN), 0);
        assertEq(imd.balanceOf(address(index)), index.idleImd() + index.feeImd(), "imd balance != idle + fee");
        vm.revertToState(snap);

        pm.setShortBy(_key(NEW_TOKEN, HOOK_G), gross * 40 / 100); // pays 60%
        vm.recordLogs();
        vm.prank(bob);
        index.rebalance();
        assertFalse(_skipped(vm.getRecordedLogs(), NEW_TOKEN, true), "a 60% fill was skipped");
        assertEq(index.held(NEW_TOKEN), gross - gross * 40 / 100);
    }
}
