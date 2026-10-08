// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared V6 settlement surface. Exact token amounts replace BPS so rounding and
/// tie allocation cannot strand value or manufacture a zero-BPS recipient.
///
/// UNAUDITED PROTOTYPE. This surface is not wired to the deployed Fuji registry, has no
/// custody integration, and must not be deployed to any network.
interface IPactSettlementV6 {
    struct Allocation {
        address recipient;
        uint256 amount;
    }

    /// @dev Every field is part of the EIP-712 message, including `registry` and
    /// `generationId`, so a signature can never be replayed against another module
    /// generation or another registry instance.
    struct SettlementAuthorization {
        uint256 pactId;
        bytes32 termsHash;
        bytes32 resultsHash;
        bytes32 evidenceHash;
        bytes32 allocationsHash;
        uint8 outcome;
        bytes32 nonce;
        uint40 deadline;
        address registry;
        bytes32 generationId;
    }

    event SettledV6(uint256 indexed pactId, address indexed verifier, bytes32 indexed authorizationDigest,
        bytes32 termsHash, bytes32 allocationsHash, bytes32 nonce, uint8 outcome, uint256 distributable);
    event RefundTimedOutV6(uint256 indexed pactId, uint256 participantCount, uint256 distributable);
    event ClaimV6(uint256 indexed pactId, address indexed recipient, uint256 amount, bool refundPath);
    /// @dev The registry bound a new Pact to this module; `verifier` is pinned for its lifetime.
    event PactBoundV6(uint256 indexed pactId, address indexed verifier);
    /// @dev Guardian incident levers. None of them moves funds to a chosen recipient or
    /// changes a written outcome; the strongest one replaces a pending split with the
    /// deterministic equal split.
    event SettlementPausedV6(bool paused);
    event VerifierRevokedV6(address indexed verifier, bool revoked);
    /// @dev A verified outcome 0/2 split waiting out the challenge window. The allocations are
    /// in the event so anyone can finalize without decoding the settlement calldata.
    event SettlementPendingV6(uint256 indexed pactId, bytes32 allocationsHash, uint40 opensAt,
        Allocation[] allocations);
    event SettlementFinalizedV6(uint256 indexed pactId, address indexed caller, bytes32 allocationsHash);
    event SettlementVetoedV6(uint256 indexed pactId, address indexed caller, bool byGuardian,
        uint256 participantCount, uint256 distributable);

    error NotRegistry();
    error NotGuardian();
    error InvalidConfiguration();
    error UnexpectedSettlementKind();
    error AuthorizationExpired();
    error NonceAlreadyConsumed();
    error RegistryMismatch();
    error TermsHashMismatch();
    error AllocationsHashMismatch();
    error NonEmptyRolloverAllocations();
    error GenerationMismatch();
    error InvalidOutcome();
    error InvalidParticipant();
    error InvalidVerifierSignature();
    error TimeoutNotReached();
    error RefundNotRepresentable();
    error RefundParticipantLimitExceeded();
    error InvalidRefundRecipient();
    error NothingToClaim();
    error ReentrantCall();
    error SettlementPaused();
    error VerifierRevoked();
    error PactNotBound();
    error PactAlreadyBound();
    error OutcomeAllocationMismatch();
    error SettlementNotPending();
    error ChallengeWindowOpen();

    function settleV6(SettlementAuthorization calldata authorization,
        Allocation[] calldata allocations, bytes calldata verifierSignature) external;

    /// @notice Registry-only liveness escape. The registry writes `Refunded`; this module owns
    /// the timing (`settlementClosesAt`, or `reviewClosesAt` once the pinned verifier is
    /// revoked) and materializes the deterministic equal split.
    function refundTimedOutV6(uint256 pactId) external;

    /// @notice Credits a pending outcome 0/2 split once its challenge window has passed.
    function finalizeSettlementV6(uint256 pactId, Allocation[] calldata allocations) external;

    /// @notice Replaces a pending split with the deterministic equal split (guardian, or anyone
    /// once the Pact's pinned verifier is revoked).
    function vetoSettlementV6(uint256 pactId) external;

    /// @notice Pays a previously credited claimable amount. There is no recipient parameter:
    /// funds can only move to the account that owns the credit.
    function claim(uint256 pactId) external;
}
