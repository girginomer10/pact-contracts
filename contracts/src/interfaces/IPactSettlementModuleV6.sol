// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactSettlementV6} from "./IPactSettlementV6.sol";

/// @notice Registry-facing surface of the V6 settlement module. The registry forwards a
/// verifier-authorized settlement and the timeout refund after it has written the terminal
/// lifecycle state. The module holds no terminal state: every entry point is `onlyRegistry`
/// and every claim is routed by the registry's `pactSettlementKind`.
///
/// UNAUDITED FUJI PROTOTYPE. Do not treat as production.
interface IPactSettlementModuleV6 {
    function settleV6(IPactSettlementV6.SettlementAuthorization calldata authorization,
        IPactSettlementV6.Allocation[] calldata allocations, bytes calldata verifierSignature) external;

    /// @dev Registry-only timeout fallback. Never permissionless: the registry decides when a
    /// Pact reached `settlementClosesAt`.
    function refundTimedOutV6(uint256 pactId) external;
}
