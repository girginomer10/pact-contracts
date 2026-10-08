// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactSettlementV6} from "./IPactSettlementV6.sol";

/// @notice Custody surface the V6 settlement module calls. The module never stores or moves
/// money itself: it authorizes a result and asks the vault to materialize the credit. The
/// vault MUST reject any caller that is not one of the domain modules configured for it.
///
/// `claimFor` exists so the module can stay the user-facing `claim` entry point while the
/// vault remains the single accounting authority; the module always passes its own
/// `msg.sender`, so a caller can only ever pull its own credit.
///
/// UNAUDITED PROTOTYPE. Do not treat as production.
interface IPactSettlementSinkV6 {
    /// @dev Credits a claim produced by a verified settlement, in full (no commission).
    function payout(uint256 pactId, address recipient, uint256 amount) external;

    /// @dev Credits a finalized outcome 0/2 split, each allocation net of the commission on the
    /// recipient's gain above its own principal; credits the commission to the two immutable
    /// commission wallets. Returns the commission collected.
    function payoutAfterCommission(uint256 pactId, IPactSettlementV6.Allocation[] calldata allocations)
        external returns (uint256 commission);

    /// @dev Credits a claim produced by the registry-gated timeout refund.
    function refundPayout(uint256 pactId, address recipient, uint256 amount) external;

    /// @dev Consumes the caller's credit and pays it out. Returns the amount paid.
    function claimFor(uint256 pactId, address recipient) external returns (uint256 amount);
}
