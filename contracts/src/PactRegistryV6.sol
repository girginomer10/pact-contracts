// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactSettlementV6} from "./interfaces/IPactSettlementV6.sol";
import {IPactSettlementRegistryV6} from "./interfaces/IPactSettlementRegistryV6.sol";
import {IPactSettlementModuleV6} from "./interfaces/IPactSettlementModuleV6.sol";
import {IPactVaultV6} from "./interfaces/IPactVaultV6.sol";
import {PactTimeoutV6} from "./libraries/PactTimeoutV6.sol";

/// @title PactRegistryV6
/// @notice Single authoritative lifecycle for the V6 walking and working Pact prototype.
///
/// Design notes (explicit, see the handoff report):
/// - The registry owns every state transition. The settlement module is stateless with respect
///   to the lifecycle: it verifies the verifier authorization, consumes the settlement nonce
///   and materializes claims, and `claim` routes a credit by reading `pactSettlementKind`
///   from this contract. The module can never settle or refund a Pact by itself.
/// - `refundTimedOutV6` on the module is `onlyRegistry`. The permissionless liveness entry
///   point is `refundWalkingPactV6`/`refundWorkingPactV6` here.
/// - Timing is immutable: `evidenceClosesAt = endAt + evidenceGrace`,
///   `reviewClosesAt = evidenceClosesAt + 24h`, `settlementClosesAt = reviewClosesAt + 24h`.
///   Walking fixes `evidenceGrace = 24h`; working accepts 0..24h. Fixed Pacts lock `startsAt`
///   and `endAt` at creation. Rolling walking Pacts fix `startsAt` (and derive `endAt`) at
///   activation. All windows are half-open.
/// - Participation is invite-only. A creator signs nothing to join their own Pact; every other
///   joiner needs an EIP-712 `InvitePermit` signed by the per-Pact invite signer. The creator
///   can rotate the signer (invalidating every outstanding permit through the epoch) and
///   block/unblock recipients on-chain while recruiting.
/// - Activation closes recruitment. When the activation deadline is missed anyone may trigger
///   `cancel*` for a full refund; the creator's return is never awaited.
///
/// UNAUDITED FUJI PROTOTYPE — not deployed, mainnet blocked, do not treat as production.
contract PactRegistryV6 is IPactSettlementRegistryV6 {
    enum Status {
        None,
        Recruiting,
        Active,
        Settled,
        Refunded,
        Cancelled
    }

    enum Domain {
        Walking,
        Working
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

    uint256 public constant MIN_STAKE = 1_000_000;
    uint256 public constant MAX_STAKE = 250_000_000;
    uint8 public constant MIN_CAPACITY = 2;
    uint8 public constant MAX_CAPACITY = 20;
    uint40 public constant MAX_JOIN_WINDOW = 30 days;
    uint40 public constant MAX_START_DELAY = 7 days;
    uint40 public constant MIN_DURATION = 1 minutes;
    uint40 public constant MAX_DURATION = 366 days;
    uint40 public constant WALKING_EVIDENCE_GRACE = 24 hours;
    uint40 public constant MAX_WORKING_EVIDENCE_GRACE = 24 hours;
    uint256 public constant MAX_INVITE_PERMIT_TTL = 4 minutes;
    /// @dev Rollover opt-in window, starting at the finalization transaction.
    uint40 public constant ROLLOVER_WINDOW = 7 days;
    /// @dev Settlement authorization outcome that opens the rollover path.
    uint8 public constant ROLLOVER_OUTCOME = 3;
    /// @dev `IPactVaultV6.rolloverState` value for a locked-but-unmoved reserve.
    uint8 internal constant VAULT_ROLLOVER_LOCKED = 1;

    /// @dev Fixed, human-readable generation label for the Fuji prototype. Mixing in the
    /// chain id and this deployment's address makes the value unique per deployment.
    bytes32 public constant GENERATION_LABEL = keccak256("PactRegistryV6.fuji.prototype.1");

    bytes32 public constant INVITE_PERMIT_TYPEHASH = keccak256(
        "InvitePermit(uint256 pactId,bytes32 termsHash,address recipient,uint256 inviteEpoch,uint40 deadline,bytes32 nonce)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant DOMAIN_NAME_HASH = keccak256("PactRegistryV6");
    bytes32 internal constant DOMAIN_VERSION_HASH = keccak256("1");

    uint256 internal constant UNLOCKED = 1;
    uint256 internal constant LOCKED = 2;

    address public immutable stakeToken;
    IPactVaultV6 public immutable vault;
    /// @dev Walking-domain settlement module.
    IPactSettlementModuleV6 public immutable walkingModule;
    /// @dev Working-domain settlement module; zero when the working domain is not deployed.
    IPactSettlementModuleV6 public immutable workingModule;
    address public immutable defaultInviteSigner;
    bytes32 public immutable generationId;

    uint256 public nextPactId = 1;

    mapping(uint256 pactId => PactV6 pact) public pacts;
    /// Immutable accepted fallback. Legacy create selectors are fail-closed (false).
    mapping(uint256 pactId => bool allowed) public rolloverAllowed;
    mapping(uint256 pactId => address[] participants) internal participantList;
    /// @dev 1-based position in the active roster; 0 means "not active".
    mapping(uint256 pactId => mapping(address participant => uint256 position)) internal participantPosition;
    mapping(uint256 pactId => mapping(address participant => bool participated)) public hasParticipated;
    mapping(uint256 pactId => uint256 epoch) public inviteEpoch;
    mapping(uint256 pactId => address signer) public inviteSigner;
    mapping(uint256 pactId => mapping(address recipient => bool blocked)) public isInviteBlocked;
    mapping(uint256 pactId => mapping(bytes32 nonce => bool used)) public usedInviteNonce;

    /// @dev Rollover consent records, keyed by source Pact -> destination Pact -> member. The
    /// stored value is the approved destination `termsHash` (zero means no live approval).
    mapping(uint256 sourcePactId => mapping(uint256 destinationPactId
        => mapping(address member => bytes32 approvedTermsHash))) public rolloverApproval;
    /// @dev Source Pact -> opt-in deadline (0 when the Pact settled without a rollover).
    mapping(uint256 sourcePactId => uint40 deadline) public rolloverDeadline;
    /// @dev A single member rejection makes the reserve refundable immediately.
    mapping(uint256 sourcePactId => bool rejected) public rolloverRejected;

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
    error ModuleNotConfigured();
    error InvalidSettlement();
    error InvalidInvitePermit();
    error InvitePermitUsed();
    error InviteParticipantBlocked();
    error RolloverUnavailable();
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
    /// @dev Fixed Pacts emit this with the times already derived at creation; rolling Pacts
    /// derive `startsAt`/`endAt`/windows here.
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
    /// @dev Post-start exit. `refund` is a claim in the vault; the penalty stays in the pool.
    event ParticipantExitedV6(
        uint256 indexed pactId, address indexed participant, uint256 principal, uint256 penalty, uint256 refund
    );
    event RolloverLockedV6(uint256 indexed pactId, uint256 amount, uint40 deadline);
    event RolloverApprovalChangedV6(
        uint256 indexed sourcePactId, uint256 indexed destinationPactId, address indexed participant, bool approved
    );
    event RolloverRejectedV6(uint256 indexed sourcePactId, address indexed participant);
    event RolloverReleasedV6(uint256 indexed sourcePactId, address indexed caller, uint256 amount);
    event RolloverConsumedV6(
        uint256 indexed sourcePactId, uint256 indexed destinationPactId, uint256 amount
    );
    /// @dev Emitted when swap-pop moves the last roster entry into a vacated slot, so an
    /// indexer can rebuild `settlementParticipantAt` order from history alone.
    event ParticipantSwapV6(
        uint256 indexed pactId, address indexed movedParticipant, uint256 fromIndex, uint256 toIndex
    );
    event WalkingPactCancelledV6(
        uint256 indexed pactId, address indexed caller, uint256 participantCount, uint256 refundedTotal
    );
    event WorkingPactCancelledV6(
        uint256 indexed pactId, address indexed caller, uint256 participantCount, uint256 refundedTotal
    );
    event WalkingPactSettledV6(
        uint256 indexed pactId, address indexed caller, bytes32 allocationsHash, uint8 outcome
    );
    event WorkingPactSettledV6(
        uint256 indexed pactId, address indexed caller, bytes32 allocationsHash, uint8 outcome
    );
    event WalkingPactRefundedV6(
        uint256 indexed pactId, address indexed caller, uint256 participantCount, uint256 distributable
    );
    event WorkingPactRefundedV6(
        uint256 indexed pactId, address indexed caller, uint256 participantCount, uint256 distributable
    );

    modifier nonReentrant() {
        if (locked != UNLOCKED) revert Reentrancy();
        locked = LOCKED;
        _;
        locked = UNLOCKED;
    }

    constructor(address stakeToken_, address vault_, address walkingModule_, address workingModule_,
        address inviteSigner_
    ) {
        // Mirrors the V5 deployment guard: the prototype refuses to exist on any network
        // other than Avalanche Fuji or a local test chain.
        if (block.chainid != 43113 && block.chainid != 31337) revert InvalidConfiguration();
        if (stakeToken_ == address(0) || stakeToken_.code.length == 0
            || vault_ == address(0) || vault_.code.length == 0
            || walkingModule_ == address(0) || inviteSigner_ == address(0)) {
            revert InvalidConfiguration();
        }
        // The vault is already deployed and must point back at this registry's final address
        // (passed as a CREATE-predicted address by the deployment script) and at both modules.
        IPactVaultV6 candidate = IPactVaultV6(vault_);
        if (candidate.stakeToken() != stakeToken_ || candidate.registry() != address(this)
            || candidate.module() != walkingModule_ || candidate.workingModule() != workingModule_) {
            revert InvalidConfiguration();
        }
        stakeToken = stakeToken_;
        vault = candidate;
        walkingModule = IPactSettlementModuleV6(walkingModule_);
        workingModule = IPactSettlementModuleV6(workingModule_);
        defaultInviteSigner = inviteSigner_;
        generationId = keccak256(abi.encodePacked(GENERATION_LABEL, block.chainid, address(this)));
    }

    // ---------------------------------------------------------------------
    // Creation: fixed walking, rolling walking, fixed working
    // ---------------------------------------------------------------------

    /// @notice Creates a calendar-day walking Pact. `startsAt` and `endAt` are fixed now and
    /// early activation never pulls the work window earlier. Walking evidence always closes
    /// 24 hours after `endAt`.
    function createWalkingPactV6(
        uint256 stakeAmount,
        uint40 joinDeadline,
        uint40 startsAt,
        uint40 duration,
        uint8 capacity,
        bytes32 termsHash,
        uint16 exitPenaltyBps
    ) external nonReentrant returns (uint256 pactId) {
        pactId = _createPact(Domain.Walking, 0, stakeAmount, joinDeadline, startsAt, duration, capacity,
            termsHash, WALKING_EVIDENCE_GRACE, exitPenaltyBps, false);
    }

    function createWalkingPactV6(
        uint256 stakeAmount,
        uint40 joinDeadline,
        uint40 startsAt,
        uint40 duration,
        uint8 capacity,
        bytes32 termsHash,
        uint16 exitPenaltyBps,
        bool allowsRollover
    ) external nonReentrant returns (uint256 pactId) {
        pactId = _createPact(Domain.Walking, 0, stakeAmount, joinDeadline, startsAt, duration, capacity,
            termsHash, WALKING_EVIDENCE_GRACE, exitPenaltyBps, allowsRollover);
    }

    /// @notice Creates a rolling-day walking Pact. The activation transaction timestamp
    /// becomes `startsAt` and `endAt = startsAt + duration`; `activationDeadline` is the last
    /// instant at which activation (and therefore recruitment) can happen.
    function createRollingWalkingPactV6(
        uint256 stakeAmount,
        uint40 joinDeadline,
        uint40 activationDeadline,
        uint40 duration,
        uint8 capacity,
        bytes32 termsHash,
        uint16 exitPenaltyBps
    ) external nonReentrant returns (uint256 pactId) {
        pactId = _createPact(Domain.Walking, 1, stakeAmount, joinDeadline, activationDeadline, duration,
            capacity, termsHash, WALKING_EVIDENCE_GRACE, exitPenaltyBps, false);
    }

    function createRollingWalkingPactV6(
        uint256 stakeAmount,
        uint40 joinDeadline,
        uint40 activationDeadline,
        uint40 duration,
        uint8 capacity,
        bytes32 termsHash,
        uint16 exitPenaltyBps,
        bool allowsRollover
    ) external nonReentrant returns (uint256 pactId) {
        pactId = _createPact(Domain.Walking, 1, stakeAmount, joinDeadline, activationDeadline, duration,
            capacity, termsHash, WALKING_EVIDENCE_GRACE, exitPenaltyBps, allowsRollover);
    }

    /// @notice Creates a fixed working Pact with an explicit evidence grace (0..24h). Requires
    /// the working domain module to be configured.
    function createWorkingPactV6(
        uint256 stakeAmount,
        uint40 joinDeadline,
        uint40 startsAt,
        uint40 duration,
        uint8 capacity,
        bytes32 termsHash,
        uint40 evidenceGrace,
        uint16 exitPenaltyBps
    ) external nonReentrant returns (uint256 pactId) {
        if (address(workingModule) == address(0)) revert ModuleNotConfigured();
        if (evidenceGrace > MAX_WORKING_EVIDENCE_GRACE) revert InvalidConfiguration();
        pactId = _createPact(Domain.Working, 0, stakeAmount, joinDeadline, startsAt, duration, capacity,
            termsHash, evidenceGrace, exitPenaltyBps, false);
    }

    function createWorkingPactV6(
        uint256 stakeAmount,
        uint40 joinDeadline,
        uint40 startsAt,
        uint40 duration,
        uint8 capacity,
        bytes32 termsHash,
        uint40 evidenceGrace,
        uint16 exitPenaltyBps,
        bool allowsRollover
    ) external nonReentrant returns (uint256 pactId) {
        if (address(workingModule) == address(0)) revert ModuleNotConfigured();
        if (evidenceGrace > MAX_WORKING_EVIDENCE_GRACE) revert InvalidConfiguration();
        pactId = _createPact(Domain.Working, 0, stakeAmount, joinDeadline, startsAt, duration, capacity,
            termsHash, evidenceGrace, exitPenaltyBps, allowsRollover);
    }

    /// @dev Every money-relevant rule is validated before the first token call. `startMode`
    /// 0 uses `activationDeadline` as the accepted `startsAt`; mode 1 stores it only as the
    /// activation deadline and leaves `startsAt`/`endAt`/windows zero until activation.
    function _createPact(
        Domain domain,
        uint8 startMode,
        uint256 stakeAmount,
        uint40 joinDeadline,
        uint40 activationDeadline,
        uint40 duration,
        uint8 capacity,
        bytes32 termsHash,
        uint40 evidenceGrace,
        uint16 exitPenaltyBps,
        bool allowsRollover
    ) private returns (uint256 pactId) {
        if (stakeAmount < MIN_STAKE || stakeAmount > MAX_STAKE || termsHash == bytes32(0)
            || capacity < MIN_CAPACITY || capacity > MAX_CAPACITY
            || joinDeadline <= block.timestamp || uint256(joinDeadline) > block.timestamp + MAX_JOIN_WINDOW
            || duration < MIN_DURATION || duration > MAX_DURATION
            || activationDeadline < joinDeadline
            || exitPenaltyBps > 10_000
            || uint256(activationDeadline) > uint256(joinDeadline) + MAX_START_DELAY) {
            revert InvalidConfiguration();
        }

        uint40 startsAt;
        uint40 endAt;
        uint40 evidenceClosesAt;
        uint40 reviewClosesAt;
        uint40 settlementClosesAt;
        if (startMode == 0) {
            startsAt = activationDeadline;
            uint256 endAtValue = uint256(startsAt) + uint256(duration);
            if (endAtValue > type(uint40).max) revert InvalidConfiguration();
            endAt = uint40(endAtValue);
            (evidenceClosesAt, reviewClosesAt, settlementClosesAt) =
                PactTimeoutV6.windows(endAt, evidenceGrace);
        }

        pactId = nextPactId++;
        rolloverAllowed[pactId] = allowsRollover;
        PactV6 storage pact = pacts[pactId];
        pact.creator = msg.sender;
        pact.termsHash = termsHash;
        pact.stakeAmount = stakeAmount;
        pact.joinDeadline = joinDeadline;
        pact.activationDeadline = activationDeadline;
        pact.startsAt = startsAt;
        pact.endAt = endAt;
        pact.duration = duration;
        pact.evidenceGrace = evidenceGrace;
        pact.evidenceClosesAt = evidenceClosesAt;
        pact.reviewClosesAt = reviewClosesAt;
        pact.settlementClosesAt = settlementClosesAt;
        pact.capacity = capacity;
        pact.domain = uint8(domain);
        pact.startMode = startMode;
        pact.exitPenaltyBps = exitPenaltyBps;
        pact.status = Status.Recruiting;

        inviteSigner[pactId] = defaultInviteSigner;
        inviteEpoch[pactId] = 1;

        _addParticipant(pactId, msg.sender);
        vault.deposit(pactId, msg.sender, stakeAmount);

        emit PactCreatedV6(pactId, msg.sender, termsHash, uint8(domain), startMode, stakeAmount,
            joinDeadline, activationDeadline, capacity, duration, evidenceGrace);
        emit ParticipantJoinedV6(pactId, msg.sender, stakeAmount, 0);
    }

    // ---------------------------------------------------------------------
    // Activation
    // ---------------------------------------------------------------------

    /// @notice Activates with at least two active participants, any time before
    /// `activationDeadline`. The creator may always call this. Once recruitment is effectively
    /// closed — `block.timestamp >= joinDeadline` (no one else can join) or the roster is at
    /// `capacity` (no one else can join either) — anyone may call it, so a server keeper can
    /// start a Pact nobody has to babysit. Activation closes recruitment. A fixed Pact keeps the
    /// `startsAt`/`endAt` accepted at creation; a rolling Pact pins `startsAt = block.timestamp`
    /// and derives `endAt` and the windows.
    function activatePactV6(uint256 pactId) external nonReentrant {
        PactV6 storage pact = _getPact(pactId);
        if (pact.status != Status.Recruiting) revert InvalidStatus();
        if (block.timestamp >= pact.activationDeadline) revert DeadlinePassed();
        if (participantList[pactId].length < 2) revert NotEnoughParticipants();
        if (msg.sender != pact.creator) {
            bool recruitmentClosed = block.timestamp >= pact.joinDeadline
                || participantList[pactId].length == pact.capacity;
            if (!recruitmentClosed) revert NotCreator();
        }

        _activate(pactId, pact);
    }

    /// @dev Shared by `activatePactV6` and `activateWithRolloverV6`: a rolling Pact pins
    /// `startsAt = block.timestamp` and derives `endAt` and the windows; a fixed Pact keeps the
    /// schedule accepted at creation.
    function _activate(uint256 pactId, PactV6 storage pact) private {
        if (pact.startMode == 1) {
            uint40 startsAt = uint40(block.timestamp);
            uint256 endAtValue = uint256(startsAt) + uint256(pact.duration);
            if (endAtValue > type(uint40).max) revert InvalidConfiguration();
            uint40 endAt = uint40(endAtValue);
            (uint40 evidenceClosesAt, uint40 reviewClosesAt, uint40 settlementClosesAt) =
                PactTimeoutV6.windows(endAt, pact.evidenceGrace);
            pact.startsAt = startsAt;
            pact.endAt = endAt;
            pact.evidenceClosesAt = evidenceClosesAt;
            pact.reviewClosesAt = reviewClosesAt;
            pact.settlementClosesAt = settlementClosesAt;
        }
        pact.status = Status.Active;

        emit PactActivatedV6(pactId, msg.sender, pact.startsAt, pact.endAt, pact.evidenceClosesAt,
            pact.reviewClosesAt, pact.settlementClosesAt);
    }

    // ---------------------------------------------------------------------
    // Invite-only participation
    // ---------------------------------------------------------------------

    function joinWalkingPactV6(InvitePermit calldata permit, bytes calldata signature) external nonReentrant {
        _join(permit, signature, Domain.Walking);
    }

    function joinWorkingPactV6(InvitePermit calldata permit, bytes calldata signature) external nonReentrant {
        _join(permit, signature, Domain.Working);
    }

    /// @notice Leaves during recruiting only (up to `joinDeadline`) and receives the full
    /// stake back. The roster is kept contiguous with swap-pop. The creator cannot leave.
    function leaveWalkingPactV6(uint256 pactId) external nonReentrant {
        _leave(pactId, Domain.Walking);
    }

    function leaveWorkingPactV6(uint256 pactId) external nonReentrant {
        _leave(pactId, Domain.Working);
    }

    /// @notice Exits an active walking Pact strictly before `endAt` with the immutable exit
    /// penalty. The refund becomes an independent vault claim; the penalty stays in the pool
    /// for the final settlement. The creator can never exit, so the active roster cannot
    /// collapse to zero.
    function exitWalkingPactV6(uint256 pactId) external nonReentrant {
        _exit(pactId, Domain.Walking);
    }

    function exitWorkingPactV6(uint256 pactId) external nonReentrant {
        _exit(pactId, Domain.Working);
    }

    /// @notice Creator-only signer rotation while recruiting. The epoch increment invalidates
    /// every permit signed before this transaction, including permits that have not been used.
    function rotateInviteSigner(uint256 pactId, address newSigner) external {
        PactV6 storage pact = _getPact(pactId);
        if (msg.sender != pact.creator) revert NotCreator();
        if (pact.status != Status.Recruiting) revert InvalidStatus();
        if (block.timestamp > pact.joinDeadline) revert DeadlinePassed();
        if (newSigner == address(0)) revert InvalidConfiguration();

        inviteSigner[pactId] = newSigner;
        uint256 epoch = ++inviteEpoch[pactId];
        emit InviteSignerRotatedV6(pactId, newSigner, epoch);
    }

    /// @notice On-chain rejection of a recipient, independent of any server-side decision.
    function blockRecipient(uint256 pactId, address recipient) external {
        _setRecipientBlocked(pactId, recipient, true);
    }

    function unblockRecipient(uint256 pactId, address recipient) external {
        _setRecipientBlocked(pactId, recipient, false);
    }

    // ---------------------------------------------------------------------
    // Cancellation: creator abort while recruiting, permissionless full-refund
    // recovery once the activation deadline is missed
    // ---------------------------------------------------------------------

    function cancelWalkingPactV6(uint256 pactId) external nonReentrant {
        _cancel(pactId, Domain.Walking);
    }

    function cancelWorkingPactV6(uint256 pactId) external nonReentrant {
        _cancel(pactId, Domain.Working);
    }

    // ---------------------------------------------------------------------
    // Rollover: consented reserve transfer into an identical successor group
    // ---------------------------------------------------------------------

    /// @notice Records or revokes one source member's consent for a specific destination Pact.
    /// The approved value is the destination `termsHash`, so a materially different successor
    /// can never reuse an old approval. Consent is revocable until the reserve is moved.
    function approveRolloverV6(uint256 sourcePactId, uint256 destinationPactId, bool approved) external {
        _assertRollover(sourcePactId, destinationPactId);
        if (participantPosition[sourcePactId][msg.sender] == 0) revert NotParticipant();
        rolloverApproval[sourcePactId][destinationPactId][msg.sender] =
            approved ? pacts[destinationPactId].termsHash : bytes32(0);
        emit RolloverApprovalChangedV6(sourcePactId, destinationPactId, msg.sender, approved);
    }

    /// @notice A single member refusal makes the reserve refundable immediately; the reserve is
    /// never moved against a live rejection.
    function rejectRolloverV6(uint256 sourcePactId) external {
        if (vault.rolloverState(sourcePactId) != VAULT_ROLLOVER_LOCKED) revert RolloverUnavailable();
        if (participantPosition[sourcePactId][msg.sender] == 0) revert NotParticipant();
        rolloverRejected[sourcePactId] = true;
        emit RolloverRejectedV6(sourcePactId, msg.sender);
    }

    /// @notice Converts a rejected or expired reserve into per-member vault claims. Callable by
    /// anyone once a member rejected or the 7-day window closed.
    function releaseRolloverV6(uint256 sourcePactId) external nonReentrant {
        _getPact(sourcePactId);
        if (vault.rolloverState(sourcePactId) != VAULT_ROLLOVER_LOCKED) revert RolloverUnavailable();
        bool expired = block.timestamp > rolloverDeadline[sourcePactId];
        if (!rolloverRejected[sourcePactId] && !expired) revert DeadlineNotReached();

        uint256 amount = vault.rolloverReserve(sourcePactId);
        vault.releaseRolloverReserve(sourcePactId);
        emit RolloverReleasedV6(sourcePactId, msg.sender, amount);
    }

    /// @notice Creator-only atomic start: the reserve transfer and the destination activation
    /// happen in one transaction. Every source member must be in the destination roster, the
    /// two rosters must be exactly equal, and each member must have approved this destination
    /// `termsHash`. A destination that is missing one approval, differs in membership, was
    /// already activated or is past the window can never consume the reserve.
    ///
    /// @dev Deliberately NOT made permissionless like `activatePactV6`. This call both starts
    /// the destination Pact and irreversibly moves the source Pact's `rolloverReserve`
    /// (`rolloverState` LOCKED -> MOVED can never be undone or repeated). Unlike plain
    /// activation, which only affects its own single roster, this one entangles two Pacts and
    /// two creators: the destination roster is not bounded by `capacity`, so an exact
    /// source/destination roster match does not imply the destination's own recruitment is
    /// "closed" the way `joinDeadline`/`capacity` implies it for `activatePactV6` — the
    /// destination creator could still be intentionally leaving room for more joiners, or
    /// simply not ready to accept an irreversible cross-Pact fund migration yet. Every member
    /// consent and roster-equality check is already caller-independent, so this is not a
    /// fund-safety gap, only a timing/control one; the destination creator keeps that control
    /// until an independent review revisits this path.
    function activateWithRolloverV6(uint256 sourcePactId, uint256 destinationPactId)
        external nonReentrant
    {
        _assertRollover(sourcePactId, destinationPactId);
        PactV6 storage destination = _getPact(destinationPactId);
        if (rolloverRejected[sourcePactId]) revert RolloverUnavailable();
        if (msg.sender != destination.creator) revert NotCreator();

        address[] storage members = participantList[sourcePactId];
        uint256 count = members.length;
        if (count < MIN_CAPACITY || participantList[destinationPactId].length != count) {
            revert RolloverUnavailable();
        }
        for (uint256 i; i < count; ++i) {
            address member = members[i];
            if (participantPosition[destinationPactId][member] == 0
                || rolloverApproval[sourcePactId][destinationPactId][member] != destination.termsHash) {
                revert RolloverUnavailable();
            }
        }

        uint256 amount = vault.moveRolloverReserve(sourcePactId, destinationPactId);
        _activate(destinationPactId, destination);
        emit RolloverConsumedV6(sourcePactId, destinationPactId, amount);
    }

    // ---------------------------------------------------------------------
    // Settlement and timeout refund
    // ---------------------------------------------------------------------

    /// @notice Settles through the walking-domain module. Anyone may submit — including a
    /// server keeper — inside the half-open normal settlement window
    /// `[reviewClosesAt, settlementClosesAt)`. Before the window the verifier review is still
    /// running; after it the permissionless refund is the only exit. The outcome and every
    /// allocation are fully determined by the verifier-signed `authorization`/`allocations`,
    /// never by `msg.sender`, so the submitter's identity cannot change who gets paid.
    function settleWalkingPactV6(
        IPactSettlementV6.SettlementAuthorization calldata authorization,
        IPactSettlementV6.Allocation[] calldata allocations,
        bytes calldata verifierSignature
    ) external nonReentrant {
        _settle(authorization, allocations, verifierSignature, Domain.Walking);
    }

    function settleWorkingPactV6(
        IPactSettlementV6.SettlementAuthorization calldata authorization,
        IPactSettlementV6.Allocation[] calldata allocations,
        bytes calldata verifierSignature
    ) external nonReentrant {
        _settle(authorization, allocations, verifierSignature, Domain.Working);
    }

    /// @notice Permissionless liveness escape. Anyone may call once
    /// `block.timestamp >= settlementClosesAt`; the module splits the pool deterministically
    /// across the active roster and this registry marks the Pact `Refunded` in the same
    /// transaction (effects first, so a module revert rolls the status write back).
    function refundWalkingPactV6(uint256 pactId) external nonReentrant {
        _refund(pactId, Domain.Walking);
    }

    function refundWorkingPactV6(uint256 pactId) external nonReentrant {
        _refund(pactId, Domain.Working);
    }

    // ---------------------------------------------------------------------
    // IPactSettlementRegistryV6 views
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
    function pactSettlementKind(uint256 pactId) public view returns (uint8) {
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

    /// @notice Rollover facts for the source Pact: opt-in deadline, reserved amount, vault
    /// state (0 none, 1 locked, 2 moved, 3 released) and whether any member rejected.
    function rolloverOf(uint256 pactId)
        external view returns (uint40 deadline, uint256 reserve, uint8 state, bool rejected)
    {
        return (rolloverDeadline[pactId], vault.rolloverReserve(pactId),
            vault.rolloverState(pactId), rolloverRejected[pactId]);
    }

    // ---------------------------------------------------------------------
    // Invite permit EIP-712 surface
    // ---------------------------------------------------------------------

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH,
            block.chainid, address(this)));
    }

    /// @notice Canonical digest the invite signer signs. Exposed so clients and tests can
    /// compare what was signed, exactly like the module exposes `settlementDigest`.
    function invitePermitDigest(InvitePermit calldata permit) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(INVITE_PERMIT_TYPEHASH, permit.pactId, permit.termsHash,
            permit.recipient, permit.inviteEpoch, permit.deadline, permit.nonce));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _join(InvitePermit calldata permit, bytes calldata signature, Domain domain) private {
        uint256 pactId = permit.pactId;
        PactV6 storage pact = _getPact(pactId);
        if (pact.domain != uint8(domain)) revert WrongDomain();
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

    /// @dev Permit deadline is bounded twice: by a short TTL from `block.timestamp` and by the
    /// recruitment deadline. The epoch is the registry's current epoch, so a rotation
    /// invalidates every earlier permit before the signature is even recovered.
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
        address signer = inviteSigner[permit.pactId];
        if (signer == address(0)) revert InvalidInvitePermit();
        if (usedInviteNonce[permit.pactId][permit.nonce]) revert InvitePermitUsed();
        bytes32 digest = invitePermitDigest(permit);
        if (_recoverSigner(digest, signature) != signer) revert InvalidInvitePermit();
        usedInviteNonce[permit.pactId][permit.nonce] = true;
    }

    function _leave(uint256 pactId, Domain domain) private {
        PactV6 storage pact = _getPact(pactId);
        if (pact.domain != uint8(domain)) revert WrongDomain();
        if (pact.status != Status.Recruiting) revert InvalidStatus();
        if (block.timestamp > pact.joinDeadline) revert DeadlinePassed();
        if (msg.sender == pact.creator || participantPosition[pactId][msg.sender] == 0) {
            revert NotParticipant();
        }

        uint256 principal = vault.principalOf(pactId, msg.sender);
        _removeParticipant(pactId, msg.sender);
        vault.release(pactId, msg.sender);
        emit ParticipantLeftV6(pactId, msg.sender, principal);
    }

    /// @dev Post-start exit. `refund = principal - floor(principal * exitPenaltyBps / 10_000)`
    /// becomes a vault claim; the penalty stays in the Pact pool. Strictly before `endAt` and
    /// never allowed for the creator, so the active roster can never drop to zero.
    function _exit(uint256 pactId, Domain domain) private {
        PactV6 storage pact = _getPact(pactId);
        if (pact.domain != uint8(domain)) revert WrongDomain();
        if (pact.status != Status.Active) revert InvalidStatus();
        if (block.timestamp >= pact.endAt) revert DeadlinePassed();
        if (msg.sender == pact.creator || participantPosition[pactId][msg.sender] == 0) {
            revert NotParticipant();
        }

        uint256 principal = vault.principalOf(pactId, msg.sender);
        uint256 penalty = principal * pact.exitPenaltyBps / 10_000;
        uint256 refund = principal - penalty;

        _removeParticipant(pactId, msg.sender);
        vault.exit(pactId, msg.sender, refund);
        emit ParticipantExitedV6(pactId, msg.sender, principal, penalty, refund);
    }

    function _setRecipientBlocked(uint256 pactId, address recipient, bool blocked) private {
        PactV6 storage pact = _getPact(pactId);
        if (msg.sender != pact.creator) revert NotCreator();
        if (pact.status != Status.Recruiting) revert InvalidStatus();
        if (block.timestamp > pact.joinDeadline) revert DeadlinePassed();
        if (recipient == address(0)) revert InvalidConfiguration();

        isInviteBlocked[pactId][recipient] = blocked;
        emit InviteRecipientBlockedV6(pactId, recipient, blocked);
    }

    function _cancel(uint256 pactId, Domain domain) private {
        PactV6 storage pact = _getPact(pactId);
        if (pact.domain != uint8(domain)) revert WrongDomain();
        if (pact.status != Status.Recruiting) revert InvalidStatus();
        // Before the activation deadline only the creator may abort. Once the deadline has
        // passed without activation, anyone may trigger the full-refund recovery; a creator
        // who disappeared can never trap the stakes.
        if (block.timestamp < pact.activationDeadline && msg.sender != pact.creator) revert NotCreator();

        address[] storage list = participantList[pactId];
        uint256 participantCount = list.length;
        uint256 refundedTotal;

        // Effects before interactions: terminal before the first credit. Cancellation is a pure
        // pull-refund: every participant gets an independent vault claim, no token transfer is
        // attempted here, so one failing recipient can never block the others.
        pact.status = Status.Cancelled;
        for (uint256 i; i < participantCount; ++i) {
            address participant = list[i];
            participantPosition[pactId][participant] = 0;
            refundedTotal += vault.principalOf(pactId, participant);
            vault.release(pactId, participant);
        }
        // Clearing the roster keeps `pactSettlementTerms`, `settlementParticipantAt` and
        // `isActiveParticipant` consistent after the credits are created.
        delete participantList[pactId];

        if (domain == Domain.Walking) {
            emit WalkingPactCancelledV6(pactId, msg.sender, participantCount, refundedTotal);
        } else {
            emit WorkingPactCancelledV6(pactId, msg.sender, participantCount, refundedTotal);
        }
    }

    function _settle(
        IPactSettlementV6.SettlementAuthorization calldata authorization,
        IPactSettlementV6.Allocation[] calldata allocations,
        bytes calldata verifierSignature,
        Domain domain
    ) private {
        uint256 pactId = authorization.pactId;
        PactV6 storage pact = _getPact(pactId);
        if (pact.domain != uint8(domain)) revert WrongDomain();
        if (pact.status != Status.Active) revert InvalidStatus();
        // Permissionless by design: the verifier signature over `authorization` (below) is the
        // only source of truth for the outcome and every allocation. `msg.sender` never gates
        // this or appears in that signed message, so anyone — a participant or a server
        // keeper — may submit it without being able to influence who gets paid what.
        if (block.timestamp < pact.reviewClosesAt) revert DeadlineNotReached();
        if (block.timestamp >= pact.settlementClosesAt) revert DeadlinePassed();
        if (authorization.termsHash != pact.termsHash) revert InvalidSettlement();
        if (authorization.outcome == ROLLOVER_OUTCOME && !rolloverAllowed[pactId]) revert RolloverUnavailable();

        // Effects first: the registry is the single lifecycle authority and the module reads
        // this terminal kind (and only that) through `pactSettlementKind`. A module revert
        // rolls the status write back with the rest of the transaction.
        pact.status = Status.Settled;
        _moduleFor(domain).settleV6(authorization, allocations, verifierSignature);

        // A verified rollover outcome carries no allocations: the whole pool moves into
        // `rolloverReserve` with deterministic equal entitlements for the final roster. The
        // registry owns the 7-day opt-in window that starts now.
        if (authorization.outcome == ROLLOVER_OUTCOME) {
            address[] storage roster = participantList[pactId];
            address[] memory members = new address[](roster.length);
            for (uint256 i; i < roster.length; ++i) members[i] = roster[i];
            uint40 deadline = uint40(block.timestamp) + ROLLOVER_WINDOW;
            vault.lockRollover(pactId, deadline, members);
            rolloverDeadline[pactId] = deadline;
            emit RolloverLockedV6(pactId, vault.rolloverReserve(pactId), deadline);
        }

        if (domain == Domain.Walking) {
            emit WalkingPactSettledV6(pactId, msg.sender, authorization.allocationsHash, authorization.outcome);
        } else {
            emit WorkingPactSettledV6(pactId, msg.sender, authorization.allocationsHash, authorization.outcome);
        }
    }

    function _refund(uint256 pactId, Domain domain) private {
        PactV6 storage pact = _getPact(pactId);
        if (pact.domain != uint8(domain)) revert WrongDomain();
        if (pact.status != Status.Active) revert InvalidStatus();
        if (block.timestamp < pact.settlementClosesAt) revert DeadlineNotReached();

        // Effects first, then the module call. No accessible order can mark the module
        // refunded while this registry is still `Open`. The distributable is read before the
        // module moves it into vault credits.
        pact.status = Status.Refunded;
        uint256 participantCount = participantList[pactId].length;
        uint256 distributable = vault.pool(pactId);
        _moduleFor(domain).refundTimedOutV6(pactId);

        if (domain == Domain.Walking) {
            emit WalkingPactRefundedV6(pactId, msg.sender, participantCount, distributable);
        } else {
            emit WorkingPactRefundedV6(pactId, msg.sender, participantCount, distributable);
        }
    }

    function _moduleFor(Domain domain) private view returns (IPactSettlementModuleV6 module) {
        module = domain == Domain.Walking ? walkingModule : workingModule;
        if (address(module) == address(0)) revert ModuleNotConfigured();
    }

    /// @dev Shared rollover preconditions. The registry remains the authority for the window;
    /// the vault re-checks its own state so a stale registry read can never move value twice.
    function _assertRollover(uint256 sourcePactId, uint256 destinationPactId) private view {
        if (sourcePactId == destinationPactId) revert RolloverUnavailable();
        PactV6 storage source = _getPact(sourcePactId);
        PactV6 storage destination = _getPact(destinationPactId);
        if (source.status != Status.Settled || destination.status != Status.Recruiting
            || destination.domain != source.domain
            || rolloverDeadline[sourcePactId] == 0
            || block.timestamp > rolloverDeadline[sourcePactId]
            || block.timestamp >= destination.activationDeadline
            || vault.rolloverState(sourcePactId) != VAULT_ROLLOVER_LOCKED) {
            revert RolloverUnavailable();
        }
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

    function _getPact(uint256 pactId) private view returns (PactV6 storage pact) {
        pact = pacts[pactId];
        if (pact.status == Status.None) revert PactNotFound(pactId);
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
