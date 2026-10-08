// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev An 18-decimal token: the V6 registry must refuse it, because MIN_STAKE/MAX_STAKE are
/// 6-decimal USDC amounts.
contract EighteenDecimalsERC20 {
    uint8 public constant decimals = 18;
    mapping(address account => uint256 balance) public balanceOf;
}
