// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice V6 window arithmetic. Every Pact derives its evidence/review/settlement boundaries
/// from the immutable `endAt` and the immutable `evidenceGrace` fixed at creation (or, for a
/// rolling Pact, at the activation transaction):
///
///   evidenceClosesAt   = endAt + evidenceGrace
///   reviewClosesAt     = evidenceClosesAt + 24 hours
///   settlementClosesAt = reviewClosesAt + 72 hours
///
/// All windows are half-open: evidence until `evidenceClosesAt`, review from
/// `evidenceClosesAt` to `reviewClosesAt`, normal settlement from `reviewClosesAt` to
/// `settlementClosesAt`, and the timeout refund from `settlementClosesAt` onward (from
/// `reviewClosesAt` once the Pact's pinned verifier is revoked; the module owns that rule).
/// The 72-hour settlement window lets the keeper or a member settle through up to three days of
/// server downtime before the result is lost to the equal refund. Fails closed on uint40
/// overflow.
library PactTimeoutV6 {
    error InvalidTimeout();

    uint40 internal constant REVIEW_WINDOW = 24 hours;
    uint40 internal constant SETTLEMENT_WINDOW = 72 hours;

    function windows(uint40 endAt, uint40 evidenceGrace)
        internal pure returns (uint40 evidenceClosesAt, uint40 reviewClosesAt, uint40 settlementClosesAt)
    {
        uint256 evidence = uint256(endAt) + uint256(evidenceGrace);
        uint256 review = evidence + REVIEW_WINDOW;
        uint256 settlement = review + SETTLEMENT_WINDOW;
        if (settlement > type(uint40).max) revert InvalidTimeout();
        return (uint40(evidence), uint40(review), uint40(settlement));
    }
}
