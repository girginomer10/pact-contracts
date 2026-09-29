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

    error NotRegistry();
    error InvalidConfiguration();
    error UnexpectedSettlementKind();
    error AuthorizationExpired();
    error NonceAlreadyConsumed();
    error RegistryMismatch();
    error TermsHashMismatch();
    error AllocationsHashMismatch();
    error NonEmptyRolloverAllocations();
    error GenerationMismatch();
    error InvalidParticipant();
    error InvalidVerifierSignature();
    error TimeoutNotReached();
    error RefundNotRepresentable();
    error RefundParticipantLimitExceeded();
    error InvalidRefundRecipient();
    error NothingToClaim();
    error ReentrantCall();

    function settleV6(SettlementAuthorization calldata authorization,
        Allocation[] calldata allocations, bytes calldata verifierSignature) external;

    /// @notice Registry-only liveness escape. The registry owns the timing decision; this
    /// function only materializes the deterministic full-refund split.
    function refundTimedOutV6(uint256 pactId) external;

    /// @notice Pays a previously credited claimable amount. There is no recipient parameter:
    /// funds can only move to the account that owns the credit.
    function claim(uint256 pactId) external;
}
