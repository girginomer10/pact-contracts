// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal stake-token surface the V6 vault needs. Return values are treated as
/// optional so USDT-style tokens that return no data are supported by exact balance-delta
/// accounting rather than by trusting the token.
///
/// UNAUDITED FUJI PROTOTYPE. Do not treat as production.
interface IPactERC20V6 {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
