// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Registry view surface the V6 settlement module reads. The registry remains the
/// single owner of the Pact lifecycle: it alone decides when a Pact is finalizable and it is
/// the only caller allowed into `settleV6`/`refundTimedOutV6`. The module stores no lifecycle
/// state of its own; `claim` routes a stored credit by reading `pactSettlementKind`.
///
/// `pactSettlementKind` encoding (mirrors the registry `Status`):
///   0 = Open      (recruiting or active)
///   1 = Settled   (signed verification settlement)
///   2 = Refunded  (timeout fallback, split across the active roster)
///   3 = Cancelled (recruitment abort, custody already returned by the registry)
///
/// UNAUDITED PROTOTYPE. No production registry implements this interface yet.
interface IPactSettlementRegistryV6 {
    /// @param termsHash hash of the immutable Pact terms the authorization is bound to
    /// @param endAt Pact end instant (0 until a rolling Pact activates)
    /// @param evidenceClosesAt end of the evidence window
    /// @param reviewClosesAt start of the normal settlement window
    /// @param settlementClosesAt end of the normal settlement window; the timeout refund opens here
    /// @param distributable exact pool the allocations must conserve
    /// @param participantCount number of active participants
    function pactSettlementTerms(uint256 pactId)
        external view returns (bytes32 termsHash, uint40 endAt, uint40 evidenceClosesAt,
            uint40 reviewClosesAt, uint40 settlementClosesAt, uint256 distributable,
            uint256 participantCount);

    function settlementParticipantAt(uint256 pactId, uint256 index) external view returns (address);

    function isActiveParticipant(uint256 pactId, address participant) external view returns (bool);

    /// @dev Single authoritative lifecycle cursor. `Open = 0`, `Settled = 1`, `Refunded = 2`,
    /// `Cancelled = 3`; reverts for an unknown Pact.
    function pactSettlementKind(uint256 pactId) external view returns (uint8);

    /// @dev Signature domain generation. The module pins it into every authorization.
    function generationId() external view returns (bytes32);
}

/// @notice Custody pointer of the registry, read by the module constructor so a module can
/// only ever be deployed against the vault its registry actually uses. Kept separate from
/// `IPactSettlementRegistryV6` because the registry exposes `vault` as a typed public
/// immutable; the ABI of both is `vault() returns (address)`.
interface IPactRegistryCustodyViewV6 {
    function vault() external view returns (address);
}
