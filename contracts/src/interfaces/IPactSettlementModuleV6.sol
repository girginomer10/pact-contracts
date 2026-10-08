// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactSettlementV6} from "./IPactSettlementV6.sol";

/// @notice Registry-facing surface of the V6 settlement module. The registry binds every new
/// Pact to the module at creation, forwards a verifier-authorized settlement and the timeout
/// refund after it has written the terminal lifecycle state. The module holds no terminal
/// state: every entry point is `onlyRegistry` and every claim is routed by the registry's
/// `pactSettlementKind`.
///
/// UNAUDITED FUJI PROTOTYPE. Do not treat as production.
interface IPactSettlementModuleV6 {
    /// @dev Called once per Pact by the registry before the first stake is pulled. Pins the
    /// module's verifier to the Pact and proves the module is live and wired to the calling
    /// registry: a module with no code, or one configured for another registry, reverts here
    /// and the creation never accepts a deposit.
    function bindPactV6(uint256 pactId) external;

    /// @dev False once the Pact's pinned verifier is revoked: such a Pact can never settle, so
    /// the registry refuses to activate it (its members keep the full-refund leave/cancel).
    function settleable(uint256 pactId) external view returns (bool);

    function settleV6(IPactSettlementV6.SettlementAuthorization calldata authorization,
        IPactSettlementV6.Allocation[] calldata allocations, bytes calldata verifierSignature) external;

    /// @dev Registry-only timeout fallback. The registry writes `Refunded` first; the module
    /// decides whether the refund is open (`settlementClosesAt`, or `reviewClosesAt` once the
    /// pinned verifier is revoked). Works while settlement is paused: it is the escape.
    function refundTimedOutV6(uint256 pactId) external;
}
