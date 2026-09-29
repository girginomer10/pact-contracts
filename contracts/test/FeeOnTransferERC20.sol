// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Adversarial test token that reports success while burning part of each
/// transfer. PactEscrow must reject it through exact balance-delta checks.
contract FeeOnTransferERC20 {
    uint256 private constant BPS_DENOMINATOR = 10_000;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    uint256 public feeBps;

    error InvalidFee();

    function setFeeBps(uint256 newFeeBps) external {
        if (newFeeBps > BPS_DENOMINATOR) revert InvalidFee();
        feeBps = newFeeBps;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved < amount) return false;
        allowance[from][msg.sender] = approved - amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private returns (bool) {
        if (balanceOf[from] < amount) return false;

        uint256 fee = (amount * feeBps) / BPS_DENOMINATOR;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        return true;
    }
}
