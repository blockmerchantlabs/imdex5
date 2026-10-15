// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The slice of Uniswap v4's PoolManager that Imdex5 uses. `BalanceDelta` is the packed
/// int256 the real manager returns: amount0 in the upper 128 bits, amount1 in the lower.
interface IPoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
    function exttload(bytes32 slot) external view returns (bytes32);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @notice A launch registry: which launch numbers it records and the artifacts of each.
interface IRegistry {
    struct Artifact {
        bytes32 role;
        bytes32 name;
        address addr;
    }

    function isRecorded(uint64 launch) external view returns (bool);
    function artifactsOf(uint64 launch) external view returns (Artifact[] memory);
}

/// @notice The IdentityMD Intake, version 2.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId);
}
