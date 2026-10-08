// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactSettlementV6} from "./interfaces/IPactSettlementV6.sol";
import {IPactSettlementRegistryV6, IPactRegistryCustodyViewV6} from "./interfaces/IPactSettlementRegistryV6.sol";
import {IPactSettlementSinkV6} from "./interfaces/IPactSettlementSinkV6.sol";
import {PactAllocationsV6} from "./libraries/PactAllocationsV6.sol";
import {PactTimeoutV6} from "./libraries/PactTimeoutV6.sol";

/// @notice V6 settlement authorization and claim routing module.
///
/// The registry owns the Pact lifecycle and is the only caller allowed into the signed
/// settlement and the timeout refund. The module itself:
/// - pins its immutable verifier to every Pact the registry binds at creation (`bindPactV6`),
/// - verifies a full EIP-712 verifier authorization (domain + every message field) against
///   that pinned verifier — an EOA through `ecrecover`, or a contract through EIP-1271 so the
///   verifier can be a threshold or HSM-backed signer,
/// - checks it is being called for the lifecycle kind the registry has already written
///   (`Settled` for `settleV6`, `Refunded` for `refundTimedOutV6`),
/// - enforces the shape of the outcome codes the verifier cannot reinterpret: outcome 1
///   (refund) must be exactly the deterministic equal split over the whole active roster and
///   outcome 2 (fallback) an equal split of its recipients; outcome 0 (performance) is
///   verifier-determined and is NOT loss-bounded on-chain,
/// - holds every outcome 0/2 split for `challengeWindow` before any credit exists, so a
///   leaked verifier key cannot be paid out before the guardian can react,
/// - at finalize, credits a split that is the equal split of the whole frozen roster (each
///   member `base` or `base + 1`, whatever the outcome code) in full, exactly like a veto or
///   the timeout refund would, and asks the vault to credit any other split net of the
///   generation's commission on each recipient's gain (`payoutAfterCommission`),
/// - routes `claim` to the vault for its caller: the module never chooses a recipient.
///
/// Incident levers (guardian only; none of them can pay anyone a chosen amount or rewrite an
/// outcome — the strongest one forces the deterministic equal split):
/// - `pauseSettlement` blocks new bindings and new signed settlements. It never blocks a
///   finalize, a veto, the timeout refund or a claim, so it can never freeze funds.
/// - `setVerifierRevoked` blocks settlement and finalization for Pacts pinned to a leaked key,
///   lets anyone veto their pending splits, opens their timeout refund at `reviewClosesAt`,
///   and blocks new bindings.
/// - `vetoSettlementV6` replaces one pending split with the deterministic equal split.
/// The verifier is immutable: there is deliberately no rotation, because a guardian-chosen
/// verifier would give the guardian outcome power. Recovery from a leaked or lost verifier is
/// revoke (+ pause) here and a new generation for new Pacts.
///
/// A rollover authorization (`outcome == 3`) carries no allocations: the module verifies and
/// consumes it, then the registry moves the pool into `rolloverReserve` with the same equal
/// split a veto would produce, so it needs no challenge window. No settlement can mint a
/// second claim for a reserve that was moved or released.
///
/// UNAUDITED PROTOTYPE. See `docs/TODO-mainnet-hardening.md` for the outstanding work.
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

    /// @dev Outcome codes produced by the server evaluators: 0 performance, 1 refund,
    /// 2 fallback (closest wins), 3 rollover. Anything above is refused before any effect.
    uint8 internal constant REFUND_OUTCOME = 1;
    uint8 internal constant FALLBACK_OUTCOME = 2;
    uint8 internal constant ROLLOVER_OUTCOME = 3;
    uint8 public constant MAX_OUTCOME = 3;
    /// @dev Bounds of the immutable challenge window between a signed outcome 0/2 split and
    /// the first instant its credits can be materialized.
    uint40 public constant MIN_CHALLENGE_WINDOW = 1 hours;
    uint40 public constant MAX_CHALLENGE_WINDOW = 7 days;
    /// @dev `pendingPayout[pactId].state` values. NONE -> PENDING (settleV6) -> FINALIZED or
    /// VETOED, both terminal.
    uint8 internal constant PAYOUT_NONE = 0;
    uint8 internal constant PAYOUT_PENDING = 1;
    uint8 internal constant PAYOUT_FINALIZED = 2;
    uint8 internal constant PAYOUT_VETOED = 3;
    /// @dev EIP-1271 `isValidSignature(bytes32,bytes)` selector and magic return value.
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;

    uint256 internal constant UNLOCKED = 1;
    uint256 internal constant LOCKED = 2;

    /// @dev A verified, nonce-consumed outcome 0/2 split whose credits are not materialized
    /// yet. `allocationsHash` is the signed hash; `opensAt` the first instant `finalize` may run.
    struct PendingPayout {
        bytes32 allocationsHash;
        uint40 opensAt;
        uint8 state;
    }

    address public immutable registry;
    address public immutable sink;
    /// @dev Incident key. Expected to be a cold key or a multisig; never the verifier.
    address public immutable guardian;
    /// @dev The only key (EOA or EIP-1271 contract) that can author settlements for Pacts of
    /// this module. Immutable by design: see the contract notes.
    address public immutable verifier;
    /// @dev Delay between a signed outcome 0/2 settlement and its claimability.
    uint40 public immutable challengeWindow;

    bool public settlementPaused;

    mapping(uint256 pactId => mapping(bytes32 nonce => bool consumed)) public consumedNonce;
    mapping(uint256 pactId => address verifier) public pactVerifier;
    mapping(address verifier => bool revoked) public revokedVerifier;
    mapping(uint256 pactId => PendingPayout pending) public pendingPayout;

    uint256 internal locked = UNLOCKED;

    /// @dev The registry must already exist and must point at `sink_` as its vault, so a
    /// module can only ever be deployed against the custody its registry actually uses.
    constructor(address registry_, address verifier_, address sink_, address guardian_, uint40 challengeWindow_) {
        if (registry_ == address(0) || verifier_ == address(0) || sink_ == address(0)
            || guardian_ == address(0) || guardian_ == verifier_ || registry_.code.length == 0
            || challengeWindow_ < MIN_CHALLENGE_WINDOW || challengeWindow_ > MAX_CHALLENGE_WINDOW) {
            revert InvalidConfiguration();
        }
        if (IPactRegistryCustodyViewV6(registry_).vault() != sink_) revert InvalidConfiguration();
        registry = registry_;
        verifier = verifier_;
        sink = sink_;
        guardian = guardian_;
        challengeWindow = challengeWindow_;
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    modifier nonReentrant() {
        if (locked != UNLOCKED) revert ReentrantCall();
        locked = LOCKED;
        _;
        locked = UNLOCKED;
    }

    // ---------------------------------------------------------------------
    // Registry-only lifecycle entry points
    // ---------------------------------------------------------------------

    /// @notice Pins the verifier to a newly created Pact. Registry-only and once per Pact;
    /// refused while settlement is paused or the verifier is revoked, so no Pact is created
    /// that could not settle normally. (Joins are not gated here: the registry refuses to
    /// activate a Pact whose verifier is revoked, through `settleable`.)
    function bindPactV6(uint256 pactId) external onlyRegistry {
        if (pactVerifier[pactId] != address(0)) revert PactAlreadyBound();
        if (settlementPaused) revert SettlementPaused();
        address current = verifier;
        if (revokedVerifier[current]) revert VerifierRevoked();
        pactVerifier[pactId] = current;
        emit PactBoundV6(pactId, current);
    }

    /// @notice False once the Pact's pinned verifier is revoked (or the Pact is unbound): such a
    /// Pact can never settle, so the registry refuses to activate it.
    function settleable(uint256 pactId) external view returns (bool) {
        address pinned = pactVerifier[pactId];
        return pinned != address(0) && !revokedVerifier[pinned];
    }

    /// @notice Consumes a registry-authorized settlement. The registry must first write
    /// `Settled`, which this module verifies through `pactSettlementKind`; everything else
    /// about the lifecycle stays with the registry. Signature, outcome-shape and allocation
    /// constraints are enforced here against the verifier pinned at binding.
    /// - outcome 1 is credited at once: it must equal the deterministic equal split, which is
    ///   exactly what a veto or the timeout refund would credit, so a delay protects nothing;
    /// - outcomes 0 and 2 are only recorded as pending for `challengeWindow`;
    /// - outcome 3 carries no allocations; the registry locks the equal-split rollover reserve.
    function settleV6(SettlementAuthorization calldata authorization,
        Allocation[] calldata allocations, bytes calldata verifierSignature) external onlyRegistry
    {
        uint256 pactId = authorization.pactId;
        if (_settlementKind(pactId) != KIND_SETTLED) revert UnexpectedSettlementKind();
        if (settlementPaused) revert SettlementPaused();
        address pinned = pactVerifier[pactId];
        if (pinned == address(0)) revert PactNotBound();
        if (revokedVerifier[pinned]) revert VerifierRevoked();
        uint8 outcome = authorization.outcome;
        if (outcome > MAX_OUTCOME) revert InvalidOutcome();
        if (block.timestamp > authorization.deadline) revert AuthorizationExpired();
        if (consumedNonce[pactId][authorization.nonce]) revert NonceAlreadyConsumed();
        if (authorization.registry != registry) revert RegistryMismatch();
        if (pendingPayout[pactId].state != PAYOUT_NONE) revert UnexpectedSettlementKind();

        (bytes32 termsHash, , , , , uint256 distributable, uint256 participantCount) = _pactTerms(pactId);
        if (authorization.termsHash != termsHash) revert TermsHashMismatch();
        if (authorization.generationId != IPactSettlementRegistryV6(registry).generationId()) {
            revert GenerationMismatch();
        }

        if (outcome == ROLLOVER_OUTCOME) {
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
            // Recipients are distinct active members, so a full-length refund list is exactly
            // the roster; with the equal-split check it is the timeout refund's split.
            if (outcome == REFUND_OUTCOME && allocations.length != participantCount) {
                revert OutcomeAllocationMismatch();
            }
            if (outcome == REFUND_OUTCOME || outcome == FALLBACK_OUTCOME) {
                _requireEqualSplit(allocations, distributable);
            }
        }

        bytes32 digest = settlementDigest(authorization);
        if (!_isValidSignature(pinned, digest, verifierSignature)) revert InvalidVerifierSignature();

        // Effects only. Funds stay in custody until each owner claims.
        consumedNonce[pactId][authorization.nonce] = true;
        if (outcome == REFUND_OUTCOME) {
            for (uint256 i; i < allocations.length; ++i) {
                IPactSettlementSinkV6(sink).payout(pactId, allocations[i].recipient, allocations[i].amount);
            }
        } else if (outcome != ROLLOVER_OUTCOME) {
            // Nothing is credited yet: a verifier-authored split becomes claimable only after
            // the challenge window, during which the guardian (or anyone, once the pinned
            // verifier is revoked) can replace it with the deterministic equal split.
            uint40 opensAt = uint40(block.timestamp) + challengeWindow;
            pendingPayout[pactId] = PendingPayout(authorization.allocationsHash, opensAt, PAYOUT_PENDING);
            emit SettlementPendingV6(pactId, authorization.allocationsHash, opensAt, allocations);
        }
        emit SettledV6(pactId, pinned, digest, termsHash, authorization.allocationsHash,
            authorization.nonce, outcome, distributable);
    }

    /// @notice Materializes a pending split's credits once its challenge window has passed.
    /// Permissionless: the allocations must hash to the signed value recorded at settlement,
    /// so the caller can choose nothing. Refused while the pinned verifier is revoked (that
    /// Pact can then only end through `vetoSettlementV6`). Not gated by the pause, so a pause
    /// can never freeze an accepted settlement. The whole-roster equal split is credited in
    /// full; any other split is credited net of the vault's commission on each gain.
    function finalizeSettlementV6(uint256 pactId, Allocation[] calldata allocations) external nonReentrant {
        PendingPayout storage pending = pendingPayout[pactId];
        if (pending.state != PAYOUT_PENDING) revert SettlementNotPending();
        if (block.timestamp < pending.opensAt) revert ChallengeWindowOpen();
        if (revokedVerifier[pactVerifier[pactId]]) revert VerifierRevoked();
        bytes32 allocationsHash = pending.allocationsHash;
        if (keccak256(abi.encode(allocations)) != allocationsHash) revert AllocationsHashMismatch();
        pending.state = PAYOUT_FINALIZED;
        if (_isRosterEqualSplit(pactId, allocations)) {
            // Every active member gets the same share (+1 dust unit at most): exactly what a veto
            // or the timeout refund would credit, so it is fee-free whatever the outcome code.
            for (uint256 i; i < allocations.length; ++i) {
                IPactSettlementSinkV6(sink).payout(pactId, allocations[i].recipient, allocations[i].amount);
            }
        } else {
            // The vault credits each allocation net of the generation's commission on that
            // recipient's gain above its own principal; the caller still chooses nothing.
            IPactSettlementSinkV6(sink).payoutAfterCommission(pactId, allocations);
        }
        emit SettlementFinalizedV6(pactId, msg.sender, allocationsHash);
    }

    /// @notice Replaces a pending split with the deterministic equal split over the frozen
    /// roster (exactly `refundTimedOutV6`'s split). The guardian may do this until the split is
    /// finalized; anyone may once the Pact's pinned verifier is revoked. No recipient, amount
    /// or outcome is chosen by the caller.
    function vetoSettlementV6(uint256 pactId) external nonReentrant {
        PendingPayout storage pending = pendingPayout[pactId];
        if (pending.state != PAYOUT_PENDING) revert SettlementNotPending();
        bool byGuardian = msg.sender == guardian;
        if (!byGuardian && !revokedVerifier[pactVerifier[pactId]]) revert NotGuardian();
        pending.state = PAYOUT_VETOED;
        (uint256 participantCount, uint256 distributable) = _equalSplit(pactId);
        emit SettlementVetoedV6(pactId, msg.sender, byGuardian, participantCount, distributable);
    }

    /// @notice Registry-only liveness escape. The registry writes `Refunded` first; the module
    /// owns the timing and then splits the pool deterministically. The refund opens at
    /// `settlementClosesAt`, or already at `reviewClosesAt` once the Pact's pinned verifier is
    /// revoked (such a Pact can never settle). A pause never opens it early. No caller-supplied
    /// recipient or amount exists: remainder units follow numeric wallet address order.
    /// Deliberately not gated by the pause or by verifier revocation: it is the escape hatch.
    function refundTimedOutV6(uint256 pactId) external onlyRegistry {
        if (_settlementKind(pactId) != KIND_REFUNDED) revert UnexpectedSettlementKind();
        (, , , uint40 reviewClosesAt, uint40 settlementClosesAt, , ) = _pactTerms(pactId);
        if (block.timestamp < settlementClosesAt
            && (block.timestamp < reviewClosesAt || !revokedVerifier[pactVerifier[pactId]])) {
            revert TimeoutNotReached();
        }
        (uint256 participantCount, uint256 distributable) = _equalSplit(pactId);
        emit RefundTimedOutV6(pactId, participantCount, distributable);
    }

    /// @notice Routes a claim to the vault, which owns the only claimable balance. There is no
    /// recipient parameter: the vault consumes the credit of `msg.sender`.
    function claim(uint256 pactId) external nonReentrant {
        bool refundPath = _settlementKind(pactId) == KIND_REFUNDED
            || pendingPayout[pactId].state == PAYOUT_VETOED;
        uint256 amount = IPactSettlementSinkV6(sink).claimFor(pactId, msg.sender);
        emit ClaimV6(pactId, msg.sender, amount, refundPath);
    }

    // ---------------------------------------------------------------------
    // Guardian incident levers
    // ---------------------------------------------------------------------

    /// @notice Stops new bindings and new signed settlements. Finalization, vetoes, timeout
    /// refunds and claims continue, so a pause can never freeze funds.
    function pauseSettlement(bool paused) external onlyGuardian {
        settlementPaused = paused;
        emit SettlementPausedV6(paused);
    }

    /// @notice Marks a verifier key as compromised. Pacts pinned to it can no longer settle or
    /// finalize, anyone may veto their pending splits, their timeout refund opens at
    /// `reviewClosesAt`, and no new Pact can be bound to it.
    function setVerifierRevoked(address target, bool revoked) external onlyGuardian {
        if (target == address(0)) revert InvalidConfiguration();
        revokedVerifier[target] = revoked;
        emit VerifierRevokedV6(target, revoked);
    }

    // ---------------------------------------------------------------------
    // Views and pure helpers
    // ---------------------------------------------------------------------

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
    /// clients and tests. `reviewClosesAt - evidenceClosesAt` is 24 hours and
    /// `settlementClosesAt - reviewClosesAt` is 72 hours.
    function settlementWindowClosesAt(uint40 endAt, uint40 evidenceGrace)
        external pure returns (uint40 evidenceClosesAt, uint40 reviewClosesAt, uint40 settlementClosesAt)
    {
        return PactTimeoutV6.windows(endAt, evidenceGrace);
    }

    /// @dev Deterministic equal split of the whole pool over the frozen roster, remainder units
    /// in numeric wallet order. Shared by the timeout refund and the settlement veto.
    function _equalSplit(uint256 pactId) private returns (uint256 participantCount, uint256 distributable) {
        (, , , , , distributable, participantCount) = _pactTerms(pactId);
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
    }

    /// @dev Equal split in strictly ascending recipient order with the remainder units on the
    /// lowest addresses: byte-for-byte the split `_equalSplit` and the vault's rollover lock
    /// produce. `allocations` were already validated (non-empty, sum == distributable).
    function _requireEqualSplit(Allocation[] calldata allocations, uint256 distributable) private pure {
        uint256 count = allocations.length;
        uint256 base = distributable / count;
        uint256 remainder = distributable % count;
        for (uint256 i; i < count; ++i) {
            if (allocations[i].amount != base + (i < remainder ? 1 : 0)
                || (i > 0 && uint160(allocations[i - 1].recipient) >= uint160(allocations[i].recipient))) {
                revert OutcomeAllocationMismatch();
            }
        }
    }

    /// @dev Order-independent: the allocations were validated at settlement (distinct active
    /// members, every amount > 0, sum == pool), and the roster and the pool are frozen since
    /// `Settled`, so covering the whole roster with `base` or `base + 1` each is the equal split.
    /// Its dust placement can therefore never decide whether a commission applies.
    function _isRosterEqualSplit(uint256 pactId, Allocation[] calldata allocations) private view returns (bool) {
        (, , , , , uint256 distributable, uint256 participantCount) = _pactTerms(pactId);
        if (allocations.length != participantCount) return false;
        uint256 base = distributable / participantCount;
        for (uint256 i; i < allocations.length; ++i) {
            uint256 amount = allocations[i].amount;
            if (amount != base && amount != base + 1) return false;
        }
        return true;
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

    /// @dev An EOA verifier must produce an EIP-2 canonical signature over the digest; a
    /// contract verifier must answer EIP-1271 `isValidSignature` with its magic value through a
    /// static call, so a signer contract can never re-enter or change state during settlement.
    function _isValidSignature(address signer, bytes32 digest, bytes calldata signature)
        private view returns (bool)
    {
        if (signer.code.length == 0) return _recoverSigner(digest, signature) == signer;
        (bool success, bytes memory data) =
            signer.staticcall(abi.encodeWithSelector(ERC1271_MAGIC, digest, signature));
        return success && data.length == 32 && abi.decode(data, (bytes4)) == ERC1271_MAGIC;
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
