// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {IPoolManager} from "../src/Interfaces.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20, MockIntake, MockPoolManager} from "./mocks/Mocks.sol";
import {TaxERC20} from "./mocks/TaxERC20.sol";

/// @dev Drives mints with random floors and limits against pools whose prices are moved, whose
/// liquidity runs short and whose coins tax, between redeems and rebalances that create residuals.
/// Records in ghosts every breach of the brief's MUST ATTACK rules; the invariants assert they
/// stay zero.
contract Imdex5FloorHandler is CommonBase, StdUtils {
    Imdex5 public index;
    MockERC20 public imd;
    MockPoolManager public pm;
    MockIntake public intake;
    address[] public actors;
    address[] public tokens;
    address[] public hooks;
    uint64[] public launches;
    uint256 immutable KEY_PK;

    // ghosts: each counts a breach and must stay zero
    uint256 public belowFloor; // a mint issued fewer than minShares or more than shares
    uint256 public revertedMintMoved; // a reverted mint changed a balance or the accounting
    uint256 public dilutedListCoin; // a mint lowered a list coin's holding per share
    uint256 public dilutedIdle; // a mint lowered idle IMD per share
    uint256 public overpaid; // a mint pulled more than maxImdIn
    uint256 public redeemFailed; // a redeem in kind reverted
    // coverage
    uint256 public mintsOk;
    uint256 public mintsReverted;
    uint256 public rebalances;

    constructor(
        Imdex5 index_,
        MockERC20 imd_,
        MockPoolManager pm_,
        MockIntake intake_,
        address[] memory actors_,
        address[] memory tokens_,
        address[] memory hooks_,
        uint64[] memory launches_,
        uint256 pk
    ) {
        index = index_;
        imd = imd_;
        pm = pm_;
        intake = intake_;
        actors = actors_;
        tokens = tokens_;
        hooks = hooks_;
        launches = launches_;
        KEY_PK = pk;
    }

    function _key(uint256 i) internal view returns (IPoolManager.PoolKey memory) {
        address token = tokens[i];
        (address c0, address c1) = address(imd) < token ? (address(imd), token) : (token, address(imd));
        return IPoolManager.PoolKey(c0, c1, 12_500, 60, hooks[i]);
    }

    function _isListed(address token) internal view returns (bool) {
        Imdex5.Coin[] memory cs = index.coins();
        uint256 lc = index.listCount();
        for (uint256 j; j < lc; ++j) {
            if (cs[j].token == token) return true;
        }
        return false;
    }

    function mintFirst(uint256 seed, uint256 amount) external {
        if (index.totalSupply() != 0) return;
        address who = actors[seed % actors.length];
        amount = bound(amount, 10e18, 2000e18);
        uint256[] memory minOut = new uint256[](index.listCount());
        vm.prank(who);
        try index.mintFirst(amount, minOut) {} catch {}
    }

    struct Before {
        uint256 supply;
        uint256 idle;
        uint256 fee;
        uint256 whoImd;
        uint256 whoShares;
        uint256 indexImd;
        uint256[] held;
        uint256[] bal;
        bool[] listed;
    }

    function _before(address who) internal view returns (Before memory b) {
        b.supply = index.totalSupply();
        b.idle = index.idleImd();
        b.fee = index.feeImd();
        b.whoImd = imd.balanceOf(who);
        b.whoShares = index.balanceOf(who);
        b.indexImd = imd.balanceOf(address(index));
        b.held = new uint256[](tokens.length);
        b.bal = new uint256[](tokens.length);
        b.listed = new bool[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            b.held[i] = index.held(tokens[i]);
            b.bal[i] = MockERC20(tokens[i]).balanceOf(address(index));
            b.listed[i] = _isListed(tokens[i]);
        }
    }

    function mint(uint256 seed, uint256 shares, uint256 maxIn, uint256 minShares) external {
        uint256 supply = index.totalSupply();
        if (supply == 0) return;
        address who = actors[seed % actors.length];
        shares = bound(shares, 1, supply * 2);
        maxIn = bound(maxIn, 0, imd.balanceOf(who));
        minShares = bound(minShares, 0, shares + 1);
        Before memory b = _before(who);
        vm.prank(who);
        try index.mint(shares, maxIn, minShares) {
            mintsOk++;
            uint256 minted = index.balanceOf(who) - b.whoShares;
            if (minted < minShares || minted > shares || minted == 0) belowFloor++;
            if (b.whoImd - imd.balanceOf(who) > maxIn) overpaid++;
            uint256 supply1 = index.totalSupply();
            for (uint256 i; i < tokens.length; ++i) {
                if (!b.listed[i]) continue;
                if (index.held(tokens[i]) * b.supply < b.held[i] * supply1) dilutedListCoin++;
            }
            if (index.idleImd() * b.supply < b.idle * supply1) dilutedIdle++;
        } catch {
            mintsReverted++;
            bool moved = imd.balanceOf(who) != b.whoImd || index.balanceOf(who) != b.whoShares
                || imd.balanceOf(address(index)) != b.indexImd || index.totalSupply() != b.supply
                || index.idleImd() != b.idle || index.feeImd() != b.fee;
            for (uint256 i; i < tokens.length; ++i) {
                moved = moved || index.held(tokens[i]) != b.held[i]
                    || MockERC20(tokens[i]).balanceOf(address(index)) != b.bal[i];
            }
            if (moved) revertedMintMoved++;
        }
    }

    function redeem(uint256 seed, uint256 shares) external {
        address who = actors[seed % actors.length];
        uint256 bal = index.balanceOf(who);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(who);
        try index.redeem(shares) {}
        catch {
            redeemFailed++;
        }
    }

    function redeemToImd(uint256 seed, uint256 shares) external {
        address who = actors[seed % actors.length];
        uint256 bal = index.balanceOf(who);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(who);
        try index.redeemToImd(shares, 0) {} catch {}
    }

    function claim(uint256 seed, uint256 coin) external {
        address who = actors[seed % actors.length];
        address token = tokens[coin % tokens.length];
        if (index.owed(who, token) == 0) return;
        vm.prank(who);
        try index.claim(token) {} catch {}
    }

    /// @dev An attacker's dump or pump of one pool, modelled as a free move of its reserves
    /// (the index's own accounting must not care what the price was).
    function movePrice(uint256 coin, uint256 factorBps) external {
        coin = coin % tokens.length;
        factorBps = bound(factorBps, 100, 1_000_000); // 0.01x .. 100x the coin reserve
        IPoolManager.PoolKey memory key = _key(coin);
        (uint256 r0, uint256 r1,,,,) = pm.pools(pm.poolId(key));
        bool coinIs0 = key.currency0 == tokens[coin];
        uint256 coinR = coinIs0 ? r0 : r1;
        uint256 imdR = coinIs0 ? r1 : r0;
        uint256 newCoinR = coinR * factorBps / 10_000;
        if (newCoinR < 1e18) newCoinR = 1e18;
        if (newCoinR > coinR) MockERC20(tokens[coin]).mint(address(pm), newCoinR - coinR);
        (uint256 n0, uint256 n1) = coinIs0 ? (newCoinR, imdR) : (imdR, newCoinR);
        pm.setPool(key, n0, n1);
    }

    function setTax(uint256 coin, uint256 bps) external {
        TaxERC20(tokens[coin % tokens.length]).setTax(bound(bps, 0, 10_000), false);
    }

    function setMaxIn(uint256 coin, uint256 maxIn) external {
        pm.setMaxIn(_key(coin % tokens.length), bound(maxIn, 0, 500e18));
    }

    /// @dev One full oracle round: fund, ask, deliver, submit, rebalance, to a random list.
    function rebalanceTo(uint256 listSeed, uint256 n) external {
        if (index.openSince() != 0 || index.nextList().length != 0) return;
        vm.warp(vm.getBlockTimestamp() + 7 days);
        address payer = actors[0];
        vm.prank(payer);
        index.fund(1e18);
        vm.prank(payer);
        index.ask();
        n = bound(n, 1, 5);
        bytes32[] memory ids = new bytes32[](n);
        uint256 picked;
        for (uint256 i; i < launches.length && picked < n; ++i) {
            if ((listSeed >> i) & 1 == 1 || launches.length - i <= n - picked) {
                ids[picked++] = bytes32(uint256(launches[i]));
            }
        }
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("uuid", intake.count())),
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
            agreed: 4,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 86_400)
        });
        vm.prank(address(intake));
        index.onOracleResult(intake.lastRequestId(), a, "");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_PK, index.attestationDigest(a));
        index.submit(a, abi.encodePacked(r, s, v));
        index.rebalance();
        rebalances++;
    }
}

contract Imdex5FloorInvariantTest is Imdex5Base {
    Imdex5FloorHandler handler;

    function setUp() public {
        _deployAll();
        for (uint256 i; i < tokens.length; ++i) {
            vm.etch(tokens[i], address(new TaxERC20(address(pm))).code);
        }
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        _give(alice, 1_000_000e18);
        _give(bob, 1_000_000e18);
        _give(carol, 1_000_000e18);
        handler = new Imdex5FloorHandler(index, imd, pm, intake, actors, tokens, hooks, launches, KEY_PK);
        _mintFirst(alice, 1000e18);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.mintFirst.selector;
        selectors[1] = handler.mint.selector;
        selectors[2] = handler.mint.selector;
        selectors[3] = handler.mint.selector;
        selectors[4] = handler.redeem.selector;
        selectors[5] = handler.redeemToImd.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.movePrice.selector;
        selectors[8] = handler.setTax.selector;
        selectors[9] = handler.setMaxIn.selector;
        selectors[10] = handler.rebalanceTo.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _owedTotal(address token) internal view returns (uint256) {
        return index.owed(alice, token) + index.owed(bob, token) + index.owed(carol, token);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_noMintBelowTheFloor() public view {
        assertEq(handler.belowFloor(), 0, "a mint issued fewer than minShares");
        assertEq(handler.overpaid(), 0, "a mint pulled more than maxImdIn");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_revertedMintMovesNothing() public view {
        assertEq(handler.revertedMintMoved(), 0, "a reverted mint kept IMD or changed the accounting");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_mintNeverDilutesListCoinsOrIdle() public view {
        assertEq(handler.dilutedListCoin(), 0, "a mint lowered a list coin per share");
        assertEq(handler.dilutedIdle(), 0, "a mint lowered idle IMD per share");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_redeemAlwaysPays() public view {
        assertEq(handler.redeemFailed(), 0, "a redeem in kind reverted");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_heldIsTheRealBalance() public view {
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(
                MockERC20(tokens[i]).balanceOf(address(index)),
                index.held(tokens[i]) + _owedTotal(tokens[i]),
                "coin balance != held + owed"
            );
        }
        assertEq(
            imd.balanceOf(address(index)),
            index.idleImd() + index.feeImd() + _owedTotal(address(imd)),
            "IMD balance != idle + fee + owed"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_noSharesMeansNothingHeld() public view {
        if (index.totalSupply() != 0) return;
        assertEq(index.idleImd(), 0);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(index.held(tokens[i]), 0);
        }
    }
}
