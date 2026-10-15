// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {IPoolManager} from "../src/Interfaces.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockERC20, MockIntake, MockPoolManager, MockRegistry, MockSigner, ReentrantHook} from "./mocks/Mocks.sol";

/// @dev Shared setup: every outside contract the index hard-codes is etched with a mock at its
/// mainnet address. Used by the edge and invariant suites.
abstract contract Imdex5Base is Test {
    uint256 constant KEY_PK = 0xA11CE;
    address constant HOOK_G = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
    address constant NEW_TOKEN = 0x1111111111111111111111111111111111111111;
    uint256 constant COIN_RESERVE = 1_000_000e18;
    uint256 constant IMD_RESERVE = 10_000e18;
    uint256 constant START = 1_800_000_000;

    Imdex5 index;
    MockERC20 imd;
    MockPoolManager pm;
    MockRegistry regA;
    MockRegistry regB;
    MockIntake intake;
    ReentrantHook hook;
    address signerKey;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address[] tokens;
    address[] hooks;
    uint64[] launches;

    function _deployAll() internal {
        vm.warp(START);
        index = new Imdex5();
        imd = MockERC20(index.IMD());
        vm.etch(address(imd), address(new MockERC20()).code);
        pm = MockPoolManager(index.POOL_MANAGER());
        vm.etch(address(pm), address(new MockPoolManager()).code);
        regA = MockRegistry(address(index.REGISTRY_A()));
        vm.etch(address(regA), address(new MockRegistry()).code);
        regB = MockRegistry(address(index.REGISTRY_B()));
        vm.etch(address(regB), address(new MockRegistry()).code);
        intake = MockIntake(index.INTAKE());
        vm.etch(address(intake), address(new MockIntake()).code);
        signerKey = vm.addr(KEY_PK);
        vm.etch(index.ORACLE_SIGNER(), address(new MockSigner(signerKey)).code);
        hook = ReentrantHook(HOOK_G);
        vm.etch(HOOK_G, address(new ReentrantHook()).code);

        Imdex5.Coin[] memory coins = index.coins();
        for (uint256 i = 0; i < coins.length; ++i) {
            vm.etch(coins[i].token, address(new MockERC20()).code);
            tokens.push(coins[i].token);
            hooks.push(coins[i].hook);
            launches.push(coins[i].launch);
            _setPool(coins[i].token, coins[i].hook, COIN_RESERVE, IMD_RESERVE);
            MockRegistry reg = i == 1 ? regA : regB;
            reg.record(coins[i].launch, coins[i].token, coins[i].hook);
        }
        vm.etch(NEW_TOKEN, address(new MockERC20()).code);
        _setPool(NEW_TOKEN, HOOK_G, COIN_RESERVE, IMD_RESERVE);
        regA.record(2000, NEW_TOKEN, HOOK_G);
        tokens.push(NEW_TOKEN);
        hooks.push(HOOK_G);
        launches.push(2000);

        _give(alice, 10_000e18);
        _give(bob, 10_000e18);
        _give(carol, 10_000e18);
    }

    function _give(address who, uint256 amount) internal {
        imd.mint(who, amount);
        vm.prank(who);
        imd.approve(address(index), type(uint256).max);
    }

    function _key(address token, address hook_) internal view returns (IPoolManager.PoolKey memory) {
        (address c0, address c1) = address(imd) < token ? (address(imd), token) : (token, address(imd));
        return IPoolManager.PoolKey(c0, c1, index.POOL_FEE(), index.TICK_SPACING(), hook_);
    }

    function _setPool(address token, address hook_, uint256 coinReserve, uint256 imdReserve) internal {
        IPoolManager.PoolKey memory key = _key(token, hook_);
        (uint256 r0, uint256 r1) = key.currency0 == token ? (coinReserve, imdReserve) : (imdReserve, coinReserve);
        pm.setPool(key, r0, r1);
        MockERC20(token).mint(address(pm), coinReserve);
        imd.mint(address(pm), imdReserve);
    }

    /// @dev The pool's IMD-per-coin price scaled by 1e18, from the mock's reserves.
    function _priceOf(address token, address hook_) internal view returns (uint256) {
        IPoolManager.PoolKey memory key = _key(token, hook_);
        (uint256 r0, uint256 r1,,,,) = pm.pools(pm.poolId(key));
        (uint256 coinR, uint256 imdR) = key.currency0 == token ? (r0, r1) : (r1, r0);
        return imdR * 1e18 / coinR;
    }

    function _zeros(uint256 n) internal pure returns (uint256[] memory z) {
        z = new uint256[](n);
    }

    function _mintFirst(address who, uint256 amount) internal {
        uint256[] memory minOut = _zeros(index.listCount());
        vm.prank(who);
        index.mintFirst(amount, minOut);
    }

    /// @dev Delivers `a` for the open request as the Intake would.
    function _deliver(OracleAttestation.Attestation memory a) internal {
        bytes32 id = intake.lastRequestId();
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
    }

    function _attestation(uint64[] memory list) internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            ids[i] = bytes32(uint256(list[i]));
        }
        a = OracleAttestation.Attestation({
            requestId: keccak256("oracle uuid"),
            chainId: 1,
            questionHash: keccak256("question"),
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 0,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: keccak256("panel"),
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: uint64(START),
            expiresAt: uint64(START + 86_400)
        });
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_PK, index.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _launches(uint256 n) internal view returns (uint64[] memory l) {
        Imdex5.Coin[] memory coins = index.coins();
        l = new uint64[](n);
        for (uint256 i = 0; i < n; ++i) {
            l[i] = coins[i].launch;
        }
    }

    /// @dev Funds fees, asks, delivers the answer through the intake and submits it.
    function _deliverList(uint64[] memory list) internal {
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
        OracleAttestation.Attestation memory a = _attestation(list);
        bytes32 id = intake.lastRequestId();
        bytes memory sig = _sign(a);
        vm.prank(address(intake));
        index.onOracleResult(id, a, "");
        vm.prank(bob);
        index.submit(a, sig);
    }

    function _assertImdAccounting() internal view {
        assertEq(imd.balanceOf(address(index)), index.feeImd() + index.idleImd(), "imd balance != idle + fee");
    }
}
