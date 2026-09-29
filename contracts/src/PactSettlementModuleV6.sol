// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactSettlementV6} from "./interfaces/IPactSettlementV6.sol";
import {IPactSettlementRegistryV6} from "./interfaces/IPactSettlementRegistryV6.sol";
import {IPactSettlementSinkV6} from "./interfaces/IPactSettlementSinkV6.sol";
import {PactAllocationsV6} from "./libraries/PactAllocationsV6.sol";
import {PactTimeoutV6} from "./libraries/PactTimeoutV6.sol";

/// @notice V6 settlement authorization and claim routing module.
///
/// The registry owns the Pact lifecycle and is the only caller allowed into the signed
/// settlement and the timeout refund. The module itself:
/// - verifies a full EIP-712 verifier authorization (domain + every message field),
/// - checks it is being called for the lifecycle kind the registry has already written
///   (`Settled` for `settleV6`, `Refunded` for `refundTimedOutV6`),
/// - consumes the settlement nonce and asks the vault to materialize exact credits; it stores
///   no claimable balance of its own (the vault is the single accounting source),
/// - routes `claim` to the vault for its caller: the module never chooses a recipient.
///
/// A rollover authorization (`outcome == 3`) carries no allocations: the module verifies and
/// consumes it, then the registry moves the pool into `rolloverReserve`. No settlement can
/// mint a second claim for a reserve that was moved or released.
///
/// There is no owner/admin path, and the module never moves funds itself. It keeps the
/// `claim` entry point for adapter stability; a deployment adapter may also target the vault
/// `claim` directly, because the two addresses are immutably bound to each other.
///
/// UNAUDITED PROTOTYPE. This module is NOT wired to the deployed registry, has no custody
/// integration and MUST NOT be deployed to any network. See `memory/` and
/// `docs/TODO-mainnet-hardening.md` for the outstanding integration work.
contract PactSettlementModuleV6 is IPactSettlementV6 {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev The type string must stay byte-identical to IPactSettlementV6.SettlementAuthorization.
    bytes32 internal constant AUTHORIZATION_TYPEHASH = keccak256(
        "SettlementAuthorization(uint256 pactId,bytes32 termsHash,bytes32 resultsHash,bytes32 evidenceHash,bytes32 allocationsHash,uint8 outcome,bytes32 nonce,uint40 deadline,address registry,bytes32 generationId)"
    );
    bytes32 internal constant DOMAIN_NAME_HASH = keccak256("PactSettlementModuleV6");
    bytes32 internal constant DOMAIN_VERSION_HASH = keccak256("1");

    /// @dev `pactSettlementKind` values owned by the registry.
    uint8 internal constant KIND_OPEN = 0;
    uint8 internal constant KIND_SETTLED = 1;
    uint8 internal constant KIND_REFUNDED = 2;

    /// @dev Outcome that opens the rollover path; mirrors the Working evaluator.
    uint8 internal constant ROLLOVER_OUTCOME = 3;

    uint256 internal constant UNLOCKED = 1;
    uint256 internal constant LOCKED = 2;

    address public immutable registry;
    address public immutable verifier;
    address public immutable sink;

    mapping(uint256 pactId => mapping(bytes32 nonce => bool consumed)) public consumedNonce;

    uint256 internal locked = UNLOCKED;

    constructor(address registry_, address verifier_, address sink_) {
        if (registry_ == address(0) || verifier_ == address(0) || sink_ == address(0)) {
            revert InvalidConfiguration();
        }
        registry = registry_;
        verifier = verifier_;
        sink = sink_;
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    modifier nonReentrant() {
        if (locked != UNLOCKED) revert ReentrantCall();
        locked = LOCKED;
        _;
        locked = UNLOCKED;
    }

    /// @notice Consumes a registry-authorized settlement. The registry must first write
    /// `Settled`, which this module verifies through `pactSettlementKind`; everything else
    /// about the lifecycle stays with the registry. Signature and allocation constraints are
    /// enforced here and every credit is materialized by the vault.
    function settleV6(SettlementAuthorization calldata authorization,
        Allocation[] calldata allocations, bytes calldata verifierSignature) external onlyRegistry
    {
        uint256 pactId = authorization.pactId;
        if (_settlementKind(pactId) != KIND_SETTLED) revert UnexpectedSettlementKind();
        if (block.timestamp > authorization.deadline) revert AuthorizationExpired();
        if (consumedNonce[pactId][authorization.nonce]) revert NonceAlreadyConsumed();
        if (authorization.registry != registry) revert RegistryMismatch();

        (bytes32 termsHash, , , , , uint256 distributable, ) = _pactTerms(pactId);
        if (authorization.termsHash != termsHash) revert TermsHashMismatch();
        if (authorization.generationId != IPactSettlementRegistryV6(registry).generationId()) {
            revert GenerationMismatch();
        }

        bool rollover = authorization.outcome == ROLLOVER_OUTCOME;
        if (rollover) {
            // A rollover carries no allocations: the reserve split is the deterministic equal
            // one the registry locks, not a verifier-authored distribution.
            if (allocations.length != 0) revert NonEmptyRolloverAllocations();
            if (keccak256(abi.encode(allocations)) != authorization.allocationsHash) {
                revert AllocationsHashMismatch();
            }
        } else {
            if (PactAllocationsV6.validate(allocations, distributable) != authorization.allocationsHash) {
                revert AllocationsHashMismatch();
            }
            for (uint256 i; i < allocations.length; ++i) {
                if (!IPactSettlementRegistryV6(registry).isActiveParticipant(pactId, allocations[i].recipient)) {
                    revert InvalidParticipant();
                }
            }
        }

        bytes32 digest = settlementDigest(authorization);
        if (_recoverSigner(digest, verifierSignature) != verifier) revert InvalidVerifierSignature();

        // Effects only. Funds stay in custody until each owner claims.
        consumedNonce[pactId][authorization.nonce] = true;
        if (!rollover) {
            for (uint256 i; i < allocations.length; ++i) {
                IPactSettlementSinkV6(sink).payout(pactId, allocations[i].recipient, allocations[i].amount);
            }
        }
        emit SettledV6(pactId, verifier, digest, termsHash, authorization.allocationsHash,
            authorization.nonce, authorization.outcome, distributable);
    }

    /// @notice Registry-only liveness escape after the immutable timeout. The registry is
    /// responsible for reaching `settlementClosesAt` and writing `Refunded` first; the module
    /// re-reads both facts and then splits the pool deterministically. No caller-supplied
    /// recipient or amount exists: remainder units follow numeric wallet address order.
    function refundTimedOutV6(uint256 pactId) external onlyRegistry {
        if (_settlementKind(pactId) != KIND_REFUNDED) revert UnexpectedSettlementKind();

        (, , , , uint40 settlementClosesAt, uint256 distributable, uint256 participantCount) =
            _pactTerms(pactId);
        if (block.timestamp < settlementClosesAt) revert TimeoutNotReached();

        if (participantCount > PactAllocationsV6.MAX_PARTICIPANTS) revert RefundParticipantLimitExceeded();
        if (participantCount == 0 || distributable < participantCount) revert RefundNotRepresentable();

        address[] memory members = new address[](participantCount);
        for (uint256 i; i < participantCount; ++i) {
            members[i] = IPactSettlementRegistryV6(registry).settlementParticipantAt(pactId, i);
        }
        PactAllocationsV6.sortAddresses(members);
        uint256 base = distributable / participantCount;
        uint256 remainder = distributable % participantCount;
        for (uint256 i; i < participantCount; ++i) {
            address recipient = members[i];
            if (recipient == address(0) || (i > 0 && members[i - 1] == recipient)) revert InvalidRefundRecipient();
            IPactSettlementSinkV6(sink).refundPayout(pactId, recipient, base + (i < remainder ? 1 : 0));
        }
        emit RefundTimedOutV6(pactId, participantCount, distributable);
    }

    /// @notice Routes a claim to the vault, which owns the only claimable balance. There is no
    /// recipient parameter: the vault consumes the credit of `msg.sender`.
    function claim(uint256 pactId) external nonReentrant {
        bool refundPath = _settlementKind(pactId) == KIND_REFUNDED;
        uint256 amount = IPactSettlementSinkV6(sink).claimFor(pactId, msg.sender);
        emit ClaimV6(pactId, msg.sender, amount, refundPath);
    }

    /// @notice Canonical EIP-712 digest for the full authorization message. Exposed so the
    /// registry, clients and tests can compare what the verifier signed.
    function settlementDigest(SettlementAuthorization calldata authorization) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization.pactId,
            authorization.termsHash, authorization.resultsHash, authorization.evidenceHash,
            authorization.allocationsHash, authorization.outcome, authorization.nonce,
            authorization.deadline, authorization.registry, authorization.generationId));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// @notice Current EIP-712 domain separator. Computed per call so a chain fork cannot
    /// reuse a cached chainId.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH,
            block.chainid, address(this)));
    }

    /// @notice Exposed pure helper so integration tests can lock exact-allocation semantics
    /// before the registry adapter is connected.
    function validateAllocations(Allocation[] calldata allocations, uint256 distributable)
        external pure returns (bytes32)
    {
        return PactAllocationsV6.validate(allocations, distributable);
    }

    /// @notice Pure derivation of the half-open boundaries the registry enforces, exposed for
    /// clients and tests. `reviewClosesAt - evidenceClosesAt` and
    /// `settlementClosesAt - reviewClosesAt` are both exactly 24 hours.
    function settlementWindowClosesAt(uint40 endAt, uint40 evidenceGrace)
        external pure returns (uint40 evidenceClosesAt, uint40 reviewClosesAt, uint40 settlementClosesAt)
    {
        return PactTimeoutV6.windows(endAt, evidenceGrace);
    }

    function _settlementKind(uint256 pactId) private view returns (uint8) {
        return IPactSettlementRegistryV6(registry).pactSettlementKind(pactId);
    }

    function _pactTerms(uint256 pactId)
        private view returns (bytes32 termsHash, uint40 endAt, uint40 evidenceClosesAt,
            uint40 reviewClosesAt, uint40 settlementClosesAt, uint256 distributable,
            uint256 participantCount)
    {
        return IPactSettlementRegistryV6(registry).pactSettlementTerms(pactId);
    }

    /// @dev EIP-2 canonical signature only: exactly 65 bytes, v in {27, 28}, low-s, and a
    /// non-zero recovery result.
    function _recoverSigner(bytes32 digest, bytes calldata signature) private pure returns (address signer) {
        if (signature.length != 65) revert InvalidVerifierSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v != 27 && v != 28) revert InvalidVerifierSignature();
        if (s == bytes32(0) ||
            uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidVerifierSignature();
        }
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidVerifierSignature();
    }
}
