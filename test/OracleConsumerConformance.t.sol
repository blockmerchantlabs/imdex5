// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @title The conformance test a consumer copies
/// @notice Ties Imdex5 to what the oracle actually signs: the protocol's vector values and its
/// digest. Imdex5 has a constant signer and no constructor arguments, so the delivered-signature
/// tests of the reference (which need the vector's test signer) are replaced by the digest and
/// selector checks, which are what tie the struct, type string and domain to the protocol's.
contract OracleConsumerConformanceTest is Test {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";
    string constant FAILURE = "onOracleFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)";

    Imdex5 consumer;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        deployCodeTo("Imdex5.sol:Imdex5", VECTOR_CONSUMER);
        consumer = Imdex5(VECTOR_CONSUMER);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    /// @notice The digest the consumer verifies is the one the oracle signs.
    function test_digestMatchesTheProtocol() public view {
        assertEq(
            consumer.attestationDigest(vector()),
            VECTOR_DIGEST,
            "struct, type string or domain differs from the protocol's"
        );
    }

    /// @notice The callback's selector is the one the intake calls.
    function test_callbackSelectorIsCanonical() public view {
        assertEq(
            consumer.onOracleResult.selector,
            bytes4(keccak256(bytes(CALLBACK))),
            "callback parameters differ from the protocol's"
        );
        assertEq(consumer.onOracleFailure.selector, bytes4(keccak256(bytes(FAILURE))));
    }
}
