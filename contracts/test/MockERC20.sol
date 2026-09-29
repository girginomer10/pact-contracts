// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Deterministic ERC-20 test double. It deliberately supports returning
/// false after a state mutation so callers' atomic rollback behavior can be
/// verified against real EVM bytecode.
contract MockERC20 {
    string public constant name = "Mock USD Coin";
    string public constant symbol = "mUSDC";
    uint8 public constant decimals = 6;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    mapping(address recipient => bool blocked) public blockedRecipient;

    function setRecipientBlocked(address recipient, bool blocked) external { blockedRecipient[recipient] = blocked; }

    bool public mutateTransfers = true;
    bool public transfersSucceed = true;

    function setMutateTransfers(bool shouldMutate) external {
        mutateTransfers = shouldMutate;
    }

    function setTransfersSucceed(bool succeeds) external {
        transfersSucceed = succeeds;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (!mutateTransfers) return transfersSucceed && !blockedRecipient[to];
        if (balanceOf[msg.sender] < amount) return false;

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return transfersSucceed && !blockedRecipient[to];
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (!mutateTransfers) return transfersSucceed && !blockedRecipient[to];
        uint256 approved = allowance[from][msg.sender];
        if (approved < amount || balanceOf[from] < amount) return false;

        allowance[from][msg.sender] = approved - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return transfersSucceed && !blockedRecipient[to];
    }
}
