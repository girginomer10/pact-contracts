// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactSettlementV6} from "./interfaces/IPactSettlementV6.sol";
import {IPactSettlementRegistryV6} from "./interfaces/IPactSettlementRegistryV6.sol";
import {IPactSettlementModuleV6} from "./interfaces/IPactSettlementModuleV6.sol";
import {IPactGemVaultV6} from "./interfaces/IPactGemVaultV6.sol";
import {IPactERC20V6} from "./interfaces/IPactERC20V6.sol";

/// @title PactGemRegistryV6
/// @notice Single authoritative lifecycle for the gem generation (Walking, Working, Proof).
///
/// Differences from `PactRegistryV6` (the USDC generation), all deliberate:
/// - Domains are data, not code: the constructor receives one `DomainConfig` per domain
///   (settlement module, accepted evidence-grace range, whether rolling starts are allowed and
///   a label). Domain ids are positions in that list; the deployment uses 0 = Walking,
///   1 = Working, 2 = Proof. Each domain has its own `PactSettlementModuleV6` instance (and so
///   its own verifier and EIP-712 domain); the shared vault accepts exactly these modules.
/// - One entry point per action (`createPactV6`, `joinPactV6`, `leavePactV6`, `exitPactV6`,
///   `cancelPactV6`, `settlePactV6`, `refundPactV6`). Every action except creation and
///   activation names the domain it expects, so a signed wallet call for one domain can never
///   act on a Pact of another (`WrongDomain`).
/// - No rollover: a settlement authorization with outcome 3 is refused before the module runs.
/// - Timing is per generation: `reviewWindow` and `settlementWindow` are immutables fixed at
///   construction within sane bounds, the evidence grace is chosen per Pact inside its domain's
///   range, and the challenge window is the module's immutable.
///     evidenceClosesAt   = endAt + evidenceGrace
///     reviewClosesAt     = evidenceClosesAt + reviewWindow
///     settlementClosesAt = reviewClosesAt + settlementWindow
///   All windows are half-open, exactly as in the USDC generation.
///
/// Unchanged security properties: the registry owns every lifecycle transition and writes the
/// terminal state before calling the module; settlement is permissionless but fully determined
/// by the domain verifier's EIP-712 signature; the module's guardian can pause, revoke and veto;
/// the permissionless timeout refund is the liveness escape; participation is invite-only via
/// EIP-712 `InvitePermit`s with a short TTL, an epoch and a per-Pact nonce.
///
/// Solo Pacts are not on chain (MIN_CAPACITY stays 2): see docs/architecture/gem-generation.md.
///
/// UNAUDITED FUJI-ONLY PROTOTYPE. The constructor refuses every chain except Avalanche Fuji
/// (43113) and the local test chain (31337). Never represent this as production-safe.
contract PactGemRegistryV6 is IPactSettlementRegistryV6 {
    enum Status {
        None,
        Recruiting,
        Active,
        Settled,
        Refunded,
        Cancelled
    }

    /// @dev `startMode`: 0 = fixed (`startsAt` accepted at creation), 1 = rolling (`startsAt`
    /// becomes the activation timestamp). `exitPenaltyBps` is immutable per Pact.
    struct PactV6 {
        address creator;
        bytes32 termsHash;
        uint256 stakeAmount;
        uint40 joinDeadline;
        uint40 activationDeadline;
        uint40 startsAt;
        uint40 endAt;
        uint40 duration;
        uint40 evidenceGrace;
        uint40 evidenceClosesAt;
        uint40 reviewClosesAt;
        uint40 settlementClosesAt;
        uint8 capacity;
        uint8 domain;
        uint8 startMode;
        uint16 exitPenaltyBps;
        Status status;
    }

    /// @dev One per domain, fixed at construction. `label` is a short ASCII name
    /// ("walking", "working", "proof") for tooling; the contract never interprets it.
    struct DomainConfig {
        IPactSettlementModuleV6 module;
        uint40 minEvidenceGrace;
        uint40 maxEvidenceGrace;
        bool allowsRolling;
        bytes32 label;
    }

    /// @dev Every field is part of the EIP-712 message. `inviteEpoch` invalidates all permits
    /// issued before a `rotateInviteSigner`; `nonce` is consumed per Pact on first use.
    struct InvitePermit {
        uint256 pactId;
        bytes32 termsHash;
        address recipient;
        uint256 inviteEpoch;
        uint40 deadline;
        bytes32 nonce;
    }

    /// @dev Stake limits in 6-decimal gem units: 1..250 gems.
    uint256 public constant MIN_STAKE = 1_000_000;
    uint256 public constant MAX_STAKE = 250_000_000;
    uint8 public constant MIN_CAPACITY = 2;
    uint8 public constant MAX_CAPACITY = 20;
    uint256 public constant MAX_DOMAINS = 4;
    uint40 public constant MAX_JOIN_WINDOW = 30 days;
    uint40 public constant MAX_START_DELAY = 7 days;
    uint40 public constant MIN_DURATION = 1 minutes;
    uint40 public constant MAX_DURATION = 366 days;
    uint40 public constant MAX_EVIDENCE_GRACE = 7 days;
    uint40 public constant MIN_REVIEW_WINDOW = 1 hours;
    uint40 public constant MAX_REVIEW_WINDOW = 24 hours;
    /// @dev The settlement window is the keeper's downtime budget before a result is lost to the
    /// equal refund; it never shortens below half a day.
    uint40 public constant MIN_SETTLEMENT_WINDOW = 12 hours;
    uint40 public constant MAX_SETTLEMENT_WINDOW = 7 days;
    uint256 public constant MAX_INVITE_PERMIT_TTL = 4 minutes;
    /// @dev Settlement outcome code of the USDC generation's rollover; refused here.
    uint8 internal constant ROLLOVER_OUTCOME = 3;

    bytes32 public constant GENERATION_LABEL = keccak256("PactGemRegistryV6.fuji.prototype.1");
    bytes32 public constant INVITE_PERMIT_TYPEHASH = keccak256(
        "InvitePermit(uint256 pactId,bytes32 termsHash,address recipient,uint256 inviteEpoch,uint40 deadline,bytes32 nonce)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant DOMAIN_NAME_HASH = keccak256("PactGemRegistryV6");
    bytes32 internal constant DOMAIN_VERSION_HASH = keccak256("1");

    uint256 internal constant UNLOCKED = 1;
    uint256 internal constant LOCKED = 2;

    address public immutable stakeToken;
    IPactGemVaultV6 public immutable vault;
    address public immutable defaultInviteSigner;
    bytes32 public immutable generationId;
    uint40 public immutable reviewWindow;
    uint40 public immutable settlementWindow;

    uint256 public nextPactId = 1;

    DomainConfig[] internal domains;
    mapping(uint256 pactId => PactV6 pact) public pacts;
    mapping(uint256 pactId => address[] participants) internal participantList;
    /// @dev 1-based position in the active roster; 0 means "not active".
    mapping(uint256 pactId => mapping(address participant => uint256 position)) internal participantPosition;
    mapping(uint256 pactId => mapping(address participant => bool participated)) public hasParticipated;
    mapping(uint256 pactId => uint256 epoch) public inviteEpoch;
    mapping(uint256 pactId => address signer) public inviteSigner;
    mapping(uint256 pactId => mapping(address recipient => bool blocked)) public isInviteBlocked;
    mapping(uint256 pactId => mapping(bytes32 nonce => bool used)) public usedInviteNonce;

    uint256 internal locked = UNLOCKED;

    error InvalidConfiguration();
    error PactNotFound(uint256 pactId);
    error InvalidStatus();
    error WrongDomain();
    error NotCreator();
    error NotParticipant();
    error AlreadyParticipant();
    error CapacityReached();
    error DeadlinePassed();
    error DeadlineNotReached();
    error NotEnoughParticipants();
    error InvalidSettlement();
    error InvalidInvitePermit();
    error InvitePermitUsed();
    error InviteParticipantBlocked();
    error OutcomeUnavailable();
    error SettlementUnavailable();
    error Reentrancy();

    event PactCreatedV6(
        uint256 indexed pactId,
        address indexed creator,
        bytes32 indexed termsHash,
        uint8 domain,
        uint8 startMode,
        uint256 stakeAmount,
        uint40 joinDeadline,
        uint40 activationDeadline,
        uint8 capacity,
        uint40 duration,
        uint40 evidenceGrace
    );
    event PactActivatedV6(
        uint256 indexed pactId,
        address indexed caller,
        uint40 startsAt,
        uint40 endAt,
        uint40 evidenceClosesAt,
        uint40 reviewClosesAt,
        uint40 settlementClosesAt
    );
    event InviteSignerRotatedV6(uint256 indexed pactId, address indexed signer, uint256 epoch);
    event InviteRecipientBlockedV6(uint256 indexed pactId, address indexed recipient, bool blocked);
    event ParticipantJoinedV6(
        uint256 indexed pactId, address indexed participant, uint256 amount, uint256 position
    );
    event ParticipantLeftV6(uint256 indexed pactId, address indexed participant, uint256 refund);
    event ParticipantExitedV6(
        uint256 indexed pactId, address indexed participant, uint256 principal, uint256 penalty, uint256 refund
    );
    event ParticipantSwapV6(
        uint256 indexed pactId, address indexed movedParticipant, uint256 fromIndex, uint256 toIndex
    );
    event PactCancelledV6(
        uint256 indexed pactId, address indexed caller, uint8 domain, uint256 participantCount, uint256 refundedTotal
    );
    event PactSettledV6(
        uint256 indexed pactId, address indexed caller, uint8 domain, bytes32 allocationsHash, uint8 outcome
    );
    event PactRefundedV6(
        uint256 indexed pactId, address indexed caller, uint8 domain, uint256 participantCount, uint256 distributable
    );

    modifier nonReentrant() {
        if (locked != UNLOCKED) revert Reentrancy();
        locked = LOCKED;
        _;
        locked = UNLOCKED;
    }

    constructor(address stakeToken_, address vault_, address inviteSigner_, uint40 reviewWindow_,
        uint40 settlementWindow_, DomainConfig[] memory domains_)
    {
        if (block.chainid != 43113 && block.chainid != 31337) revert InvalidConfiguration();
        if (stakeToken_ == address(0) || stakeToken_.code.length == 0
            || vault_ == address(0) || vault_.code.length == 0 || inviteSigner_ == address(0)
            || reviewWindow_ < MIN_REVIEW_WINDOW || reviewWindow_ > MAX_REVIEW_WINDOW
            || settlementWindow_ < MIN_SETTLEMENT_WINDOW || settlementWindow_ > MAX_SETTLEMENT_WINDOW
            || domains_.length == 0 || domains_.length > MAX_DOMAINS) {
            revert InvalidConfiguration();
        }
        // Stake limits are 6-decimal amounts.
        if (IPactERC20V6(stakeToken_).decimals() != 6) revert InvalidConfiguration();
        // The vault is already deployed and must point back at this registry's final address and
        // accept exactly the domain modules, in domain order.
        IPactGemVaultV6 candidate = IPactGemVaultV6(vault_);
        if (candidate.stakeToken() != stakeToken_ || candidate.registry() != address(this)
            || candidate.moduleCount() != domains_.length) {
            revert InvalidConfiguration();
        }
        for (uint256 i; i < domains_.length; ++i) {
            DomainConfig memory config = domains_[i];
            if (address(config.module) != candidate.moduleAt(i) || config.label == bytes32(0)
                || config.minEvidenceGrace > config.maxEvidenceGrace
                || config.maxEvidenceGrace > MAX_EVIDENCE_GRACE) {
                revert InvalidConfiguration();
            }
            domains.push(config);
        }
        stakeToken = stakeToken_;
        vault = candidate;
        defaultInviteSigner = inviteSigner_;
        reviewWindow = reviewWindow_;
        settlementWindow = settlementWindow_;
        generationId = keccak256(abi.encodePacked(GENERATION_LABEL, block.chainid, address(this)));
    }

    // ---------------------------------------------------------------------
    // Creation and activation
    // ---------------------------------------------------------------------

    /// @notice Creates a Pact in `domain`. `startMode` 0 (fixed) treats `startsAtOrActivationDeadline`
    /// as the accepted `startsAt` and derives every window now; mode 1 (rolling, only where the
    /// domain allows it) stores it as the activation deadline and derives the schedule at
    /// activation. It must lie strictly after `joinDeadline`, so a keeper always has an instant
    /// (`joinDeadline` reached, activation still open) to start a Pact without its creator. `evidenceGrace` must lie in the domain's range. Every money-relevant rule is
    /// validated before the first token call, and the creator's stake is pulled last.
    function createPactV6(
        uint8 domain,
        uint8 startMode,
        uint256 stakeAmount,
        uint40 joinDeadline,
        uint40 startsAtOrActivationDeadline,
        uint40 duration,
        uint8 capacity,
        bytes32 termsHash,
        uint40 evidenceGrace,
        uint16 exitPenaltyBps
    ) external nonReentrant returns (uint256 pactId) {
        DomainConfig storage config = _domain(domain);
        uint40 activationDeadline = startsAtOrActivationDeadline;
        if (stakeAmount < MIN_STAKE || stakeAmount > MAX_STAKE || termsHash == bytes32(0)
            || capacity < MIN_CAPACITY || capacity > MAX_CAPACITY
            || joinDeadline <= block.timestamp || uint256(joinDeadline) > block.timestamp + MAX_JOIN_WINDOW
            || duration < MIN_DURATION || duration > MAX_DURATION
            || activationDeadline <= joinDeadline
            || uint256(activationDeadline) > uint256(joinDeadline) + MAX_START_DELAY
            || exitPenaltyBps > 10_000
            || evidenceGrace < config.minEvidenceGrace || evidenceGrace > config.maxEvidenceGrace
            || startMode > 1 || (startMode == 1 && !config.allowsRolling)) {
            revert InvalidConfiguration();
        }

        pactId = nextPactId++;
        PactV6 storage pact = pacts[pactId];
        pact.creator = msg.sender;
        pact.termsHash = termsHash;
        pact.stakeAmount = stakeAmount;
        pact.joinDeadline = joinDeadline;
        pact.activationDeadline = activationDeadline;
        pact.duration = duration;
        pact.evidenceGrace = evidenceGrace;
        pact.capacity = capacity;
        pact.domain = domain;
        pact.startMode = startMode;
        pact.exitPenaltyBps = exitPenaltyBps;
        pact.status = Status.Recruiting;
        if (startMode == 0) _schedule(pact, activationDeadline);

        inviteSigner[pactId] = defaultInviteSigner;
        inviteEpoch[pactId] = 1;

        // Binding pins the module's current verifier and proves the module is live and wired to
        // this registry before the first stake moves (no code, wrong registry, paused or revoked
        // all revert here).
        config.module.bindPactV6(pactId);

        _addParticipant(pactId, msg.sender);
        vault.deposit(pactId, msg.sender, stakeAmount);

        emit PactCreatedV6(pactId, msg.sender, termsHash, domain, startMode, stakeAmount,
            joinDeadline, activationDeadline, capacity, duration, evidenceGrace);
        emit ParticipantJoinedV6(pactId, msg.sender, stakeAmount, 0);
    }

    /// @notice Activates with at least two active participants, strictly before
    /// `activationDeadline`. The creator may always call; anyone may once recruitment is closed
    /// (`joinDeadline` reached or the roster at capacity), so a keeper can start a Pact. A rolling
    /// Pact pins `startsAt = block.timestamp` and derives the windows; a fixed Pact keeps the
    /// schedule accepted at creation. A Pact pinned to a revoked verifier is never activated.
    function activatePactV6(uint256 pactId) external nonReentrant {
        PactV6 storage pact = _getPact(pactId);
        if (pact.status != Status.Recruiting) revert InvalidStatus();
        if (block.timestamp >= pact.activationDeadline) revert DeadlinePassed();
        uint256 count = participantList[pactId].length;
        if (count < MIN_CAPACITY) revert NotEnoughParticipants();
        if (msg.sender != pact.creator && block.timestamp < pact.joinDeadline && count != pact.capacity) {
            revert NotCreator();
        }
        if (!domains[pact.domain].module.settleable(pactId)) revert SettlementUnavailable();
        if (pact.startMode == 1) _schedule(pact, uint40(block.timestamp));
        pact.status = Status.Active;

        emit PactActivatedV6(pactId, msg.sender, pact.startsAt, pact.endAt, pact.evidenceClosesAt,
            pact.reviewClosesAt, pact.settlementClosesAt);
    }

    // ---------------------------------------------------------------------
    // Invite-only participation, leave, exit, cancellation
    // ---------------------------------------------------------------------

    function joinPactV6(uint8 domain, InvitePermit calldata permit, bytes calldata signature) external nonReentrant {
        uint256 pactId = permit.pactId;
        PactV6 storage pact = _getPactIn(pactId, domain);
        if (pact.status != Status.Recruiting) revert InvalidStatus();
        if (block.timestamp > pact.joinDeadline) revert DeadlinePassed();
        if (isInviteBlocked[pactId][msg.sender]) revert InviteParticipantBlocked();
        if (hasParticipated[pactId][msg.sender]) revert AlreadyParticipant();
        uint256 position = participantList[pactId].length;
        if (position >= pact.capacity) revert CapacityReached();

        _consumeInvitePermit(permit, signature, pact);

        _addParticipant(pactId, msg.sender);
        vault.deposit(pactId, msg.sender, pact.stakeAmount);
        emit ParticipantJoinedV6(pactId, msg.sender, pact.stakeAmount, position);
    }

    /// @notice Leaves a still-recruiting Pact with the full stake as a claim. The creator cannot
    /// leave (they cancel instead).
    function leavePactV6(uint8 domain, uint256 pactId) external nonReentrant {
        PactV6 storage pact = _getPactIn(pactId, domain);
        if (pact.status != Status.Recruiting) revert InvalidStatus();
        if (msg.sender == pact.creator || participantPosition[pactId][msg.sender] == 0) revert NotParticipant();

        uint256 principal = vault.principalOf(pactId, msg.sender);
        _removeParticipant(pactId, msg.sender);
        vault.release(pactId, msg.sender);
        emit ParticipantLeftV6(pactId, msg.sender, principal);
    }

    /// @notice Exits an active Pact strictly before `endAt` with the immutable exit penalty;
    /// before `startsAt` the exit is free, and a free exit that leaves fewer than two members
    /// cancels the Pact with a full refund for the rest. The creator can never exit.
    function exitPactV6(uint8 domain, uint256 pactId) external nonReentrant {
        PactV6 storage pact = _getPactIn(pactId, domain);
        if (pact.status != Status.Active) revert InvalidStatus();
        if (block.timestamp >= pact.endAt) revert DeadlinePassed();
        if (msg.sender == pact.creator || participantPosition[pactId][msg.sender] == 0) revert NotParticipant();

        uint256 principal = vault.principalOf(pactId, msg.sender);
        bool beforeStart = block.timestamp < pact.startsAt;
        uint256 penalty = beforeStart ? 0 : principal * pact.exitPenaltyBps / 10_000;
        uint256 refund = principal - penalty;

        _removeParticipant(pactId, msg.sender);
        vault.exit(pactId, msg.sender, refund);
        emit ParticipantExitedV6(pactId, msg.sender, principal, penalty, refund);
        if (beforeStart && participantList[pactId].length < MIN_CAPACITY) _releaseAll(pactId, pact);
    }

    /// @notice Creator abort while recruiting; once the activation deadline is missed anyone
    /// may trigger the full-refund recovery.
    function cancelPactV6(uint8 domain, uint256 pactId) external nonReentrant {
        PactV6 storage pact = _getPactIn(pactId, domain);
        if (pact.status != Status.Recruiting) revert InvalidStatus();
        if (block.timestamp < pact.activationDeadline && msg.sender != pact.creator) revert NotCreator();
        _releaseAll(pactId, pact);
    }

    /// @notice Creator-only signer rotation while recruiting; the epoch increment invalidates
    /// every outstanding permit.
    function rotateInviteSigner(uint256 pactId, address newSigner) external {
        _creatorWhileRecruiting(pactId);
        if (newSigner == address(0)) revert InvalidConfiguration();
        inviteSigner[pactId] = newSigner;
        uint256 epoch = ++inviteEpoch[pactId];
        emit InviteSignerRotatedV6(pactId, newSigner, epoch);
    }

    function blockRecipient(uint256 pactId, address recipient) external {
        _setRecipientBlocked(pactId, recipient, true);
    }

    function unblockRecipient(uint256 pactId, address recipient) external {
        _setRecipientBlocked(pactId, recipient, false);
    }

    // ---------------------------------------------------------------------
    // Settlement and timeout refund
    // ---------------------------------------------------------------------

    /// @notice Settles through the Pact's domain module inside `[reviewClosesAt,
    /// settlementClosesAt)`. Anyone may submit: the domain verifier's signature alone fixes the
    /// outcome and every allocation. Outcome 3 (rollover) does not exist in this generation.
    function settlePactV6(
        uint8 domain,
        IPactSettlementV6.SettlementAuthorization calldata authorization,
        IPactSettlementV6.Allocation[] calldata allocations,
        bytes calldata verifierSignature
    ) external nonReentrant {
        uint256 pactId = authorization.pactId;
        PactV6 storage pact = _getPactIn(pactId, domain);
        if (pact.status != Status.Active) revert InvalidStatus();
        if (block.timestamp < pact.reviewClosesAt) revert DeadlineNotReached();
        if (block.timestamp >= pact.settlementClosesAt) revert DeadlinePassed();
        if (authorization.termsHash != pact.termsHash) revert InvalidSettlement();
        if (authorization.outcome == ROLLOVER_OUTCOME) revert OutcomeUnavailable();

        // Effects first: the module verifies this terminal kind through `pactSettlementKind`; a
        // module revert rolls the status write back.
        pact.status = Status.Settled;
        domains[domain].module.settleV6(authorization, allocations, verifierSignature);
        emit PactSettledV6(pactId, msg.sender, domain, authorization.allocationsHash, authorization.outcome);
    }

    /// @notice Permissionless liveness escape once the module's refund rule holds
    /// (`settlementClosesAt`, or `reviewClosesAt` for a revoked verifier). The module splits the
    /// pool equally across the active roster.
    function refundPactV6(uint8 domain, uint256 pactId) external nonReentrant {
        PactV6 storage pact = _getPactIn(pactId, domain);
        if (pact.status != Status.Active) revert InvalidStatus();
        pact.status = Status.Refunded;
        uint256 participantCount = participantList[pactId].length;
        uint256 distributable = vault.pool(pactId);
        domains[domain].module.refundTimedOutV6(pactId);
        emit PactRefundedV6(pactId, msg.sender, domain, participantCount, distributable);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IPactSettlementRegistryV6
    function pactSettlementTerms(uint256 pactId)
        external
        view
        returns (bytes32 termsHash, uint40 endAt, uint40 evidenceClosesAt, uint40 reviewClosesAt,
            uint40 settlementClosesAt, uint256 distributable, uint256 participantCount)
    {
        PactV6 storage pact = _getPact(pactId);
        return (pact.termsHash, pact.endAt, pact.evidenceClosesAt, pact.reviewClosesAt,
            pact.settlementClosesAt, vault.pool(pactId), participantList[pactId].length);
    }

    /// @inheritdoc IPactSettlementRegistryV6
    function settlementParticipantAt(uint256 pactId, uint256 index) external view returns (address) {
        return participantList[pactId][index];
    }

    /// @inheritdoc IPactSettlementRegistryV6
    function isActiveParticipant(uint256 pactId, address participant) external view returns (bool) {
        return participantPosition[pactId][participant] != 0;
    }

    /// @inheritdoc IPactSettlementRegistryV6
    function pactSettlementKind(uint256 pactId) external view returns (uint8) {
        Status status = pacts[pactId].status;
        if (status == Status.None) revert PactNotFound(pactId);
        if (status == Status.Settled) return 1;
        if (status == Status.Refunded) return 2;
        if (status == Status.Cancelled) return 3;
        return 0;
    }

    function activeParticipantCount(uint256 pactId) external view returns (uint256) {
        return participantList[pactId].length;
    }

    function poolOf(uint256 pactId) external view returns (uint256) {
        return vault.pool(pactId);
    }

    function domainCount() external view returns (uint256) {
        return domains.length;
    }

    function domainConfig(uint8 domain) external view returns (DomainConfig memory) {
        return _domain(domain);
    }

    /// @notice The half-open boundaries this generation derives for a Pact ending at `endAt`.
    function windowsFor(uint40 endAt, uint40 evidenceGrace)
        public view returns (uint40 evidenceClosesAt, uint40 reviewClosesAt, uint40 settlementClosesAt)
    {
        uint256 evidence = uint256(endAt) + uint256(evidenceGrace);
        uint256 review = evidence + reviewWindow;
        uint256 settlement = review + settlementWindow;
        if (settlement > type(uint40).max) revert InvalidConfiguration();
        return (uint40(evidence), uint40(review), uint40(settlement));
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH,
            block.chainid, address(this)));
    }

    function invitePermitDigest(InvitePermit calldata permit) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(INVITE_PERMIT_TYPEHASH, permit.pactId, permit.termsHash,
            permit.recipient, permit.inviteEpoch, permit.deadline, permit.nonce));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _schedule(PactV6 storage pact, uint40 startsAt) private {
        uint256 endAtValue = uint256(startsAt) + uint256(pact.duration);
        if (endAtValue > type(uint40).max) revert InvalidConfiguration();
        (uint40 evidenceClosesAt, uint40 reviewClosesAt, uint40 settlementClosesAt) =
            windowsFor(uint40(endAtValue), pact.evidenceGrace);
        pact.startsAt = startsAt;
        pact.endAt = uint40(endAtValue);
        pact.evidenceClosesAt = evidenceClosesAt;
        pact.reviewClosesAt = reviewClosesAt;
        pact.settlementClosesAt = settlementClosesAt;
    }

    /// @dev Permit deadline is bounded by a short TTL and by the recruitment deadline; the epoch
    /// is the current one, so a rotation invalidates every earlier permit.
    function _consumeInvitePermit(InvitePermit calldata permit, bytes calldata signature, PactV6 storage pact)
        private
    {
        if (permit.recipient != msg.sender || permit.termsHash != pact.termsHash
            || permit.nonce == bytes32(0) || permit.inviteEpoch != inviteEpoch[permit.pactId]
            || permit.deadline < block.timestamp
            || uint256(permit.deadline) > block.timestamp + MAX_INVITE_PERMIT_TTL
            || uint256(permit.deadline) > pact.joinDeadline) {
            revert InvalidInvitePermit();
        }
        if (usedInviteNonce[permit.pactId][permit.nonce]) revert InvitePermitUsed();
        if (_recoverSigner(invitePermitDigest(permit), signature) != inviteSigner[permit.pactId]) {
            revert InvalidInvitePermit();
        }
        usedInviteNonce[permit.pactId][permit.nonce] = true;
    }

    function _creatorWhileRecruiting(uint256 pactId) private view returns (PactV6 storage pact) {
        pact = _getPact(pactId);
        if (msg.sender != pact.creator) revert NotCreator();
        if (pact.status != Status.Recruiting) revert InvalidStatus();
        if (block.timestamp > pact.joinDeadline) revert DeadlinePassed();
    }

    function _setRecipientBlocked(uint256 pactId, address recipient, bool blocked) private {
        _creatorWhileRecruiting(pactId);
        if (recipient == address(0)) revert InvalidConfiguration();
        isInviteBlocked[pactId][recipient] = blocked;
        emit InviteRecipientBlockedV6(pactId, recipient, blocked);
    }

    /// @dev Cancels with a full refund for every remaining member: recruiting cancellation and the
    /// pre-start collapse of an activated Pact. Pure pull-refunds, no token transfer here.
    function _releaseAll(uint256 pactId, PactV6 storage pact) private {
        address[] storage list = participantList[pactId];
        uint256 participantCount = list.length;
        uint256 refundedTotal;
        pact.status = Status.Cancelled;
        for (uint256 i; i < participantCount; ++i) {
            address participant = list[i];
            participantPosition[pactId][participant] = 0;
            refundedTotal += vault.principalOf(pactId, participant);
            vault.release(pactId, participant);
        }
        delete participantList[pactId];
        emit PactCancelledV6(pactId, msg.sender, pact.domain, participantCount, refundedTotal);
    }

    function _addParticipant(uint256 pactId, address participant) private {
        participantList[pactId].push(participant);
        participantPosition[pactId][participant] = participantList[pactId].length;
        hasParticipated[pactId][participant] = true;
    }

    function _removeParticipant(uint256 pactId, address participant) private {
        address[] storage list = participantList[pactId];
        uint256 index = participantPosition[pactId][participant] - 1;
        uint256 lastIndex = list.length - 1;
        if (index != lastIndex) {
            address moved = list[lastIndex];
            list[index] = moved;
            participantPosition[pactId][moved] = index + 1;
            emit ParticipantSwapV6(pactId, moved, lastIndex, index);
        }
        list.pop();
        participantPosition[pactId][participant] = 0;
    }

    function _domain(uint8 domain) private view returns (DomainConfig storage) {
        if (domain >= domains.length) revert WrongDomain();
        return domains[domain];
    }

    function _getPact(uint256 pactId) private view returns (PactV6 storage pact) {
        pact = pacts[pactId];
        if (pact.status == Status.None) revert PactNotFound(pactId);
    }

    function _getPactIn(uint256 pactId, uint8 domain) private view returns (PactV6 storage pact) {
        pact = _getPact(pactId);
        if (pact.domain != domain) revert WrongDomain();
    }

    /// @dev EIP-2 canonical signature only: exactly 65 bytes, v in {27, 28}, low-s, and a
    /// non-zero recovery result.
    function _recoverSigner(bytes32 digest, bytes calldata signature) private pure returns (address signer) {
        if (signature.length != 65) revert InvalidInvitePermit();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v != 27 && v != 28) revert InvalidInvitePermit();
        if (s == bytes32(0) ||
            uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidInvitePermit();
        }
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidInvitePermit();
    }
}
