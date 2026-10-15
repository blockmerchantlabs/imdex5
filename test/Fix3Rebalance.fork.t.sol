// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockSigner} from "./mocks/Mocks.sol";

/// The patched Imdex5 on a fork of mainnet: the oracle changes the list and anyone rebalances, with the real coins,
/// the real registries, the real PoolManager and the real Intake. Only the oracle's signer is stood in for.
contract Fix3RebalanceForkTest is Test {
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 constant KEY_PK = 0xA11CE;
    Imdex5 X;
    address alice = address(0xA11CE1);
    address bob = address(0xB0B);
    address keeper = address(0xF4A);

    function _attestation(uint64[] memory list) internal view returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](list.length);
        for (uint256 i; i < list.length; ++i) ids[i] = bytes32(uint256(list[i]));
        a = OracleAttestation.Attestation({
            requestId: keccak256("oracle uuid"), chainId: 1, questionHash: keccak256("question"),
            answerType: OracleAttestation.ANSWER_BYTES32_LIST, answer: abi.encode(ids), figure: 0,
            fromBlock: 100, toBlock: 200, blockHash: bytes32(uint256(7)), panelJobId: keccak256("panel"),
            panelSize: 5, quorum: 4, agreed: 5, issuedAt: uint64(block.timestamp), expiresAt: uint64(block.timestamp + 86_400)
        });
    }

    function _backed(string memory when) internal {
        Imdex5.Coin[] memory cs = X.coins();
        for (uint256 i; i < cs.length; ++i) {
            assertEq(IERC20(cs[i].token).balanceOf(address(X)), X.held(cs[i].token), string.concat("recorded equals real, ", when));
        }
    }

    function _run(uint256 first, uint64[] memory next) internal {
        X = new Imdex5();
        vm.etch(X.ORACLE_SIGNER(), address(new MockSigner(vm.addr(KEY_PK))).code);
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            deal(IMD, who[i], 100_000 ether);
            vm.prank(who[i]);
            IERC20(IMD).approve(address(X), type(uint256).max);
        }
        uint256[] memory minOut = new uint256[](5);
        vm.prank(alice);
        X.mintFirst(first, minOut);
        uint256 half = X.balanceOf(alice) / 2;
        vm.prank(bob);
        X.mint(half, first * 2, 0);
        vm.prank(alice);
        X.fund(2 ether);
        Imdex5.Coin[] memory before = X.coins();

        // The real Intake takes the question; the answer comes back; a stranger submits it.
        vm.warp(block.timestamp + 8 days);
        vm.prank(keeper);
        X.ask();
        bytes32 id = X.openRequest();
        assertTrue(id != bytes32(0), "the real Intake accepted the question");
        OracleAttestation.Attestation memory a = _attestation(next);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_PK, X.attestationDigest(a));
        vm.prank(X.INTAKE());
        (bool ok,) = address(X).call{gas: 200_000}(abi.encodeCall(Imdex5.onOracleResult, (id, a, "")));
        assertTrue(ok, "the callback fits in 200,000 gas");
        vm.prank(keeper);
        X.submit(a, abi.encodePacked(r, s, v));
        assertEq(X.nextList().length, next.length, "the registries were read and the next list is stored");

        vm.prank(keeper);
        uint256 g = gasleft();
        X.rebalance();
        emit log_named_uint("gas: rebalance", g - gasleft());
        _backed("after the rebalance");
        Imdex5.Coin[] memory afterList = X.coins();
        emit log_named_uint("coins held before", before.length);
        emit log_named_uint("coins held after", afterList.length);
        for (uint256 i; i < afterList.length; ++i) {
            emit log_named_uint("  launch", afterList[i].launch);
            emit log_named_decimal_uint("    held", X.held(afterList[i].token), 18);
        }
        emit log_named_decimal_uint("idle IMD after the rebalance", X.idleImd(), 18);
        emit log_named_decimal_uint("keeper earned IMD for ask, submit and rebalance", IERC20(IMD).balanceOf(keeper), 18);

        // A second rebalance needs a new list; everyone can still leave.
        uint256 bobShares = X.balanceOf(bob);
        vm.prank(bob);
        X.redeemToImd(bobShares, 0);
        _backed("after an exit to IMD");
        uint256 aliceShares = X.balanceOf(alice);
        vm.prank(alice);
        X.redeem(aliceShares);
        assertEq(X.totalSupply(), 0);
        Imdex5.Coin[] memory end = X.coins();
        for (uint256 i; i < end.length; ++i) {
            assertEq(X.held(end[i].token), 0);
            assertEq(X.owed(alice, end[i].token), 0, "nothing left owed");
            assertEq(IERC20(end[i].token).balanceOf(address(X)), 0, "nothing stranded");
        }
    }

    function test_dropTheTaxedCoin_fourRemain() public {
        uint64[] memory next = new uint64[](4);
        next[0] = 1282; next[1] = 1283; next[2] = 737; next[3] = 1075;
        _run(100 ether, next);
    }

    function test_reorderSameFive() public {
        uint64[] memory next = new uint64[](5);
        next[0] = 1283; next[1] = 1282; next[2] = 737; next[3] = 1175; next[4] = 1075;
        _run(100 ether, next);
    }

    function test_shrinkToThree_bigFund() public {
        uint64[] memory next = new uint64[](3);
        next[0] = 1282; next[1] = 1283; next[2] = 737;
        _run(1_000 ether, next);
    }
}
