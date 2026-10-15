// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev An ERC-20 that, when armed, re-enters a target during `transfer` and records whether the
/// re-entry succeeded. Used to attack `redeem` (payment path) and `claim` (owed path).
contract ReentrantERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public target;
    bytes public payload;
    bool public armed;
    uint256 public attempts;
    bool public reentered;
    bytes public lastRevert;
    /// @dev When set, the transfer reverts if the re-entry failed, so the coin becomes owed.
    bool public revertIfBlocked;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function arm(address target_, bytes calldata payload_, bool revertIfBlocked_) external {
        target = target_;
        payload = payload_;
        armed = true;
        revertIfBlocked = revertIfBlocked_;
    }

    function disarm() external {
        armed = false;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (armed) {
            attempts += 1;
            // slither-disable-next-line low-level-calls
            (bool ok, bytes memory ret) = target.call(payload);
            if (ok) reentered = true;
            else lastRevert = ret;
            if (!ok && revertIfBlocked) revert("reentry blocked");
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev A token whose `transfer` burns all the gas it is given.
contract GasBurnerERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        uint256 x;
        while (true) {
            x += 1;
        }
        return x == 0;
    }
}

/// @dev An Intake that reverts every request: the index's `ask` must then revert whole.
contract RevertingIntake {
    fallback() external payable {
        revert("intake closed");
    }
}
