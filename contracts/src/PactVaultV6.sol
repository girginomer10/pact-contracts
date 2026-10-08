// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PactAllocationsV6} from "./libraries/PactAllocationsV6.sol";

import {IPactERC20V6} from "./interfaces/IPactERC20V6.sol";
import {IPactSettlementSinkV6} from "./interfaces/IPactSettlementSinkV6.sol";
import {IPactSettlementV6} from "./interfaces/IPactSettlementV6.sol";

/// @title PactVaultV6
/// @notice Single-source ERC-20 stake accounting for the V6 prototype.
///
/// Accounting model (one ledger per Pact, no second source anywhere):
/// - `unallocatedPool[pactId]`   custody still owned by the Pact pool
/// - `rolloverReserve[pactId]`   pool moved aside for a consented successor Pact
/// - `claimable[pactId][who]`    credits already earned, not yet transferred
/// - `paidOut[pactId]`           cumulative value actually transferred out by claims
/// - `deposited[pactId]`         cumulative value pulled in by deposits
///
/// An amount is never simultaneously in two accounts: allocation/cancellation/exit moves value
/// from `unallocatedPool` (or `rolloverReserve`) into `claimable`, and `claim` consumes exactly
/// the caller's credit before the token transfer. A transfer revert rolls the consumption back
/// with the transaction. The system-wide conservation identity is
/// `tokenBalance + SUM(paidOut) == SUM(deposited)`; per Pact the backing is
/// `unallocatedPool + rolloverReserve + SUM(claimable)`.
///
/// Commission (immutable per generation, `commissionBps == 0` means none): a finalized outcome
/// 0/2 split that the module does not route as the whole-roster equal split is credited through
/// `payoutAfterCommission`, which takes `commissionBps` of each recipient's gain above its own
/// principal in that Pact (`contribution + rolloverPrincipal`, frozen since activation) and
/// credits it to the two commission wallets as ordinary pull credits of the same Pact. Refunds,
/// vetoes, cancellations, leaves, exits, rollovers and outcome 1 never pass through it. A
/// commission wallet can never be a participant, so its credits in a Pact are commission only.
///
/// Access rules:
/// - `deposit`/`release`/`exit`/rollover transitions are callable only by the immutable registry.
/// - `payout`/`payoutAfterCommission`/`refundPayout`/`claimFor` are callable only by one of the
///   two immutable modules, and every credit is bounded by that Pact's `unallocatedPool`.
/// - `claim`/`claimTo` are permissionless, but each only ever pays the address whose credit it
///   consumes (`msg.sender` for `claim`, the `recipient` argument for `claimTo`) — never the
///   caller of `claimTo` on someone else's behalf.
/// There is deliberately no owner/admin path and no arbitrary-recipient transfer.
///
/// UNAUDITED PROTOTYPE. The bytecode accepts Avalanche Fuji and Avalanche C-Chain; a mainnet
/// deployment is a separate, explicitly acknowledged owner decision and remains unaudited.
contract PactVaultV6 is IPactSettlementSinkV6 {
    uint256 internal constant UNLOCKED = 1;
    uint256 internal constant LOCKED = 2;

    uint8 internal constant ROLLOVER_NONE = 0;
    uint8 internal constant ROLLOVER_LOCKED = 1;
    uint8 internal constant ROLLOVER_MOVED = 2;
    uint8 internal constant ROLLOVER_RELEASED = 3;

    uint256 internal constant BPS = 10_000;
    /// @dev Ceiling of any generation's commission: no deployment can take more than 10% of a gain.
    uint256 public constant MAX_COMMISSION_BPS = 1_000;

    address public immutable stakeToken;
    address public immutable registry;
    /// @dev Walking-domain settlement module.
    address public immutable module;
    /// @dev Working-domain settlement module; zero when the working domain is not deployed.
    address public immutable workingModule;
    /// @dev Commission in basis points OF EACH RECIPIENT'S GAIN (allocation above its own
    /// principal) on a split credited through `payoutAfterCommission`. Zero: no commission.
    uint16 public immutable commissionBps;
    /// @dev Share of each collected commission, in basis points OF THE COMMISSION (not of the
    /// gain), credited to `operatorRecipient`; `companyRecipient` receives the rest, including
    /// the rounding remainder. 1_000 with a 500 commission = 0.5% of the gain to the operator.
    uint16 public immutable operatorShareOfCommissionBps;
    address public immutable operatorRecipient;
    address public immutable companyRecipient;

    mapping(uint256 pactId => uint256 amount) public unallocatedPool;
    mapping(uint256 pactId => uint256 amount) public rolloverReserve;
    mapping(uint256 pactId => mapping(address participant => uint256 amount)) public claimable;
    mapping(uint256 pactId => uint256 amount) public paidOut;
    mapping(uint256 pactId => uint256 amount) public deposited;

    mapping(uint256 pactId => mapping(address participant => uint256 amount)) public contribution;
    mapping(uint256 pactId => mapping(address participant => uint256 amount)) public rolloverPrincipal;

    mapping(uint256 pactId => mapping(address participant => uint256 amount)) public rolloverEntitlement;
    mapping(uint256 pactId => address[] participants) internal rolloverRecipients;
    mapping(uint256 pactId => uint8 state) public rolloverState;
    mapping(uint256 pactId => uint40 deadline) public rolloverDeadline;

    uint256 internal locked = UNLOCKED;

    error OnlyRegistry();
    error OnlyModule();
    error InvalidConfiguration();
    error InvalidSettlement();
    error RolloverUnavailable();
    error NothingToClaim();
    error TokenTransferFailed();
    /// @dev The stake token reverted; `reason` is its raw revert data (e.g. a USDC blocklist or
    /// pause reason). Wrapped, so token data can never impersonate a Pact contract error.
    error TokenCallReverted(bytes reason);
    error TokenAmountMismatch();
    error Reentrancy();

    event ContributionLockedV6(uint256 indexed pactId, address indexed participant, uint256 amount);
    /// @dev The full stake was converted into a claim instead of being pushed back.
    event ContributionReleasedV6(uint256 indexed pactId, address indexed participant, uint256 amount);
    event ExitCreditedV6(uint256 indexed pactId, address indexed participant, uint256 principal,
        uint256 refund, uint256 penalty);
    event PayoutV6(uint256 indexed pactId, address indexed recipient, uint256 amount);
    event RefundPayoutV6(uint256 indexed pactId, address indexed recipient, uint256 amount);
    event ClaimedV6(uint256 indexed pactId, address indexed recipient, uint256 amount);
    /// @dev Emitted in addition to `ClaimedV6` whenever `claimTo` pays a credit on someone
    /// else's behalf, so an indexer can tell a self-service claim from a keeper-submitted one.
    event ClaimedForV6(uint256 indexed pactId, address indexed caller, address indexed recipient, uint256 amount);
    event RolloverReservedV6(uint256 indexed pactId, uint256 amount, uint40 deadline, uint256 participantCount);
    event RolloverConsumedV6(uint256 indexed sourcePactId, uint256 indexed destinationPactId, uint256 amount);
    event RolloverReleasedV6(uint256 indexed pactId, uint256 amount, uint256 participantCount);
    /// @dev One per `payoutAfterCommission` recipient whose allocation exceeds its own principal;
    /// that recipient's `PayoutV6` carries `grossAmount - commission`.
    event CommissionChargedV6(uint256 indexed pactId, address indexed recipient, uint256 grossAmount,
        uint256 principal, uint256 commission);
    /// @dev One per `payoutAfterCommission` that collected a commission: `commission` is the sum
    /// of that call's charges, split into two pull credits of this Pact.
    event CommissionCreditedV6(uint256 indexed pactId, address indexed operatorRecipient,
        address indexed companyRecipient, uint256 commission, uint256 operatorAmount, uint256 companyAmount);

    modifier onlyRegistry() {
        if (msg.sender != registry) revert OnlyRegistry();
        _;
    }

    modifier onlyModule() {
        if (msg.sender != module && msg.sender != workingModule) revert OnlyModule();
        _;
    }

    modifier nonReentrant() {
        if (locked != UNLOCKED) revert Reentrancy();
        locked = LOCKED;
        _;
        locked = UNLOCKED;
    }

    constructor(address stakeToken_, address registry_, address module_, address workingModule_,
        uint16 commissionBps_, uint16 operatorShareOfCommissionBps_, address operatorRecipient_,
        address companyRecipient_)
    {
        // Deployment guard: Avalanche Fuji (43113), Avalanche C-Chain (43114) or a local test
        // chain (31337); the deploy tooling owns the explicit mainnet acknowledgement.
        if (block.chainid != 43113 && block.chainid != 43114 && block.chainid != 31337) revert InvalidConfiguration();
        if (stakeToken_ == address(0) || stakeToken_.code.length == 0
            || registry_ == address(0) || module_ == address(0)) {
            revert InvalidConfiguration();
        }
        stakeToken = stakeToken_;
        registry = registry_;
        module = module_;
        // The working module is deployed after the vault (CREATE-address cycle), so its
        // address is accepted as a prediction and only checked to be non-zero-or-configured.
        workingModule = workingModule_;
        if (commissionBps_ > MAX_COMMISSION_BPS || operatorShareOfCommissionBps_ > BPS) revert InvalidConfiguration();
        if (commissionBps_ == 0) {
            // The one canonical "no commission" configuration: nothing configured at all.
            if (operatorShareOfCommissionBps_ != 0 || operatorRecipient_ != address(0)
                || companyRecipient_ != address(0)) {
                revert InvalidConfiguration();
            }
        } else {
            // Two distinct external wallets: never zero, never a contract of this system.
            for (uint256 i; i < 2; ++i) {
                address recipient = i == 0 ? operatorRecipient_ : companyRecipient_;
                if (recipient == address(0) || recipient == stakeToken_ || recipient == registry_
                    || recipient == module_ || recipient == workingModule_ || recipient == address(this)) {
                    revert InvalidConfiguration();
                }
            }
            if (operatorRecipient_ == companyRecipient_) revert InvalidConfiguration();
        }
        commissionBps = commissionBps_;
        operatorShareOfCommissionBps = operatorShareOfCommissionBps_;
        operatorRecipient = operatorRecipient_;
        companyRecipient = companyRecipient_;
    }

    /// @notice Unallocated-pool alias kept for the registry/artifact surface.
    function pool(uint256 pactId) external view returns (uint256) {
        return unallocatedPool[pactId];
    }

    /// @notice Principal a participant exits with: cash contribution + credited rollover.
    function principalOf(uint256 pactId, address participant) external view returns (uint256) {
        return contribution[pactId][participant] + rolloverPrincipal[pactId][participant];
    }

    function rolloverRecipientCount(uint256 pactId) external view returns (uint256) {
        return rolloverRecipients[pactId].length;
    }

    /// @notice Pulls `amount` from `participant` and credits it to the Pact pool. Effects are
    /// written before the token call; a failed or inexact transfer reverts the whole call.
    function deposit(uint256 pactId, address participant, uint256 amount) external onlyRegistry nonReentrant {
        // A commission wallet never creates or joins a Pact, so it can never be a recipient of a
        // settlement and its credits in any Pact are commission only.
        if (participant == address(0) || amount == 0 || contribution[pactId][participant] != 0
            || participant == operatorRecipient || participant == companyRecipient) {
            revert InvalidConfiguration();
        }
        contribution[pactId][participant] = amount;
        unallocatedPool[pactId] += amount;
        deposited[pactId] += amount;
        _transferFromExact(participant, amount);
        emit ContributionLockedV6(pactId, participant, amount);
    }

    /// @notice Returns a still-recruiting participant's full principal as a claim. The registry
    /// removes the participant from its roster in the same transaction; the participant (or the
    /// module on its behalf) pulls the tokens later.
    function release(uint256 pactId, address participant) external onlyRegistry nonReentrant {
        uint256 principal = contribution[pactId][participant] + rolloverPrincipal[pactId][participant];
        if (principal == 0 || principal > unallocatedPool[pactId]) revert InvalidSettlement();
        contribution[pactId][participant] = 0;
        rolloverPrincipal[pactId][participant] = 0;
        unallocatedPool[pactId] -= principal;
        claimable[pactId][participant] += principal;
        emit ContributionReleasedV6(pactId, participant, principal);
    }

    /// @notice Credits a post-start exit: `refund` becomes a claim and the penalty stays in the
    /// Pact pool for the final settlement. The participant's whole principal is consumed, so a
    /// second exit can never double-credit.
    function exit(uint256 pactId, address participant, uint256 refund) external onlyRegistry nonReentrant {
        uint256 principal = contribution[pactId][participant] + rolloverPrincipal[pactId][participant];
        if (principal == 0 || refund > principal || refund > unallocatedPool[pactId]) {
            revert InvalidSettlement();
        }
        contribution[pactId][participant] = 0;
        rolloverPrincipal[pactId][participant] = 0;
        unallocatedPool[pactId] -= refund;
        if (refund != 0) claimable[pactId][participant] += refund;
        emit ExitCreditedV6(pactId, participant, principal, refund, principal - refund);
    }

    /// @notice Credits a verified settlement allocation in full (outcome 1, and a finalized split
    /// that is the whole-roster equal split). Module-only; cannot exceed the pool.
    function payout(uint256 pactId, address recipient, uint256 amount) external onlyModule nonReentrant {
        _credit(pactId, recipient, amount);
        emit PayoutV6(pactId, recipient, amount);
    }

    /// @notice Credits a finalized outcome 0/2 split net of the commission. Module-only. Each
    /// recipient pays `commissionBps` of the part of its allocation above its own principal in
    /// this Pact (cash contribution + credited rollover), rounded down, so nobody pays on their
    /// own principal coming back. The summed commission is split once: the operator share is
    /// rounded down and the company receives the rest. Every credit is a pull credit of this
    /// Pact, so the allocations still conserve the pool exactly. Returns the commission taken.
    function payoutAfterCommission(uint256 pactId, IPactSettlementV6.Allocation[] calldata allocations)
        external onlyModule nonReentrant returns (uint256 commission)
    {
        for (uint256 i; i < allocations.length; ++i) {
            address recipient = allocations[i].recipient;
            uint256 amount = allocations[i].amount;
            uint256 principal = contribution[pactId][recipient] + rolloverPrincipal[pactId][recipient];
            uint256 fee = _commissionOn(amount, principal);
            // fee <= floor(amount / 10) under the ceiling, so a member credit is never zero.
            _credit(pactId, recipient, amount - fee);
            emit PayoutV6(pactId, recipient, amount - fee);
            if (fee != 0) {
                commission += fee;
                emit CommissionChargedV6(pactId, recipient, amount, principal, fee);
            }
        }
        if (commission != 0) {
            uint256 operatorAmount = commission * operatorShareOfCommissionBps / BPS;
            uint256 companyAmount = commission - operatorAmount;
            if (operatorAmount != 0) _credit(pactId, operatorRecipient, operatorAmount);
            if (companyAmount != 0) _credit(pactId, companyRecipient, companyAmount);
            emit CommissionCreditedV6(pactId, operatorRecipient, companyRecipient, commission,
                operatorAmount, companyAmount);
        }
    }

    /// @notice The commission `payoutAfterCommission` would take from `amount` credited to
    /// `recipient` in `pactId`, from its current principal ("fee if charged"). It does not know
    /// the module's exemption: a finalized whole-roster equal split is credited through `payout`
    /// and pays none.
    function commissionOn(uint256 pactId, address recipient, uint256 amount) external view returns (uint256) {
        return _commissionOn(amount, contribution[pactId][recipient] + rolloverPrincipal[pactId][recipient]);
    }

    /// @notice Credits a registry-gated timeout refund. Module-only; cannot exceed the pool.
    function refundPayout(uint256 pactId, address recipient, uint256 amount) external onlyModule nonReentrant {
        _credit(pactId, recipient, amount);
        emit RefundPayoutV6(pactId, recipient, amount);
    }

    /// @dev Module-side claim entry: consumes the recipient's credit and pays it out. The module
    /// always passes its own `msg.sender`, so no caller can redirect someone else's credit.
    function claimFor(uint256 pactId, address recipient) external onlyModule nonReentrant returns (uint256 amount) {
        amount = _claim(pactId, recipient);
    }

    /// @notice Vault-side claim entry for deployments whose adapter targets the vault directly.
    function claim(uint256 pactId) external nonReentrant returns (uint256 amount) {
        amount = _claim(pactId, msg.sender);
    }

    /// @notice Permissionless payout of `recipient`'s existing credit to `recipient` only, so a
    /// server keeper (or anyone) can settle up a participant who never has to submit their own
    /// claim transaction. This reuses `_claim` exactly like `claim`/`claimFor`: it zeroes and
    /// pays `recipient`'s own credit and nobody else's, `msg.sender` never becomes the payee, and
    /// there is no recipient-choosing path here beyond the one the caller names — which can only
    /// ever be paid what that same address was already credited. A zero credit reverts
    /// `NothingToClaim`, exactly like `claim`, so it cannot be used to grief a future real claim.
    function claimTo(uint256 pactId, address recipient) external nonReentrant returns (uint256 amount) {
        amount = _claim(pactId, recipient);
        emit ClaimedForV6(pactId, msg.sender, recipient, amount);
    }

    /// @notice Moves the whole pool into `rolloverReserve` with deterministic equal entitlements
    /// (remainder units follow numeric wallet address order). The registry owns the window.
    function lockRollover(uint256 pactId, uint40 deadline, address[] calldata recipients)
        external onlyRegistry nonReentrant
    {
        uint256 available = unallocatedPool[pactId];
        uint256 count = recipients.length;
        if (rolloverState[pactId] != ROLLOVER_NONE || available == 0 || count == 0
            || deadline <= block.timestamp) {
            revert RolloverUnavailable();
        }
        address[] memory members = PactAllocationsV6.sortAddresses(recipients);
        uint256 base = available / count;
        uint256 remainder = available % count;
        for (uint256 i; i < count; ++i) {
            address recipient = members[i];
            // A zero or repeated participant would overwrite an entitlement and strand value.
            if (recipient == address(0) || (i > 0 && members[i - 1] == recipient) || rolloverEntitlement[pactId][recipient] != 0
                || contribution[pactId][recipient] + rolloverPrincipal[pactId][recipient] == 0) {
                revert InvalidSettlement();
            }
            rolloverEntitlement[pactId][recipient] = base + (i < remainder ? 1 : 0);
            rolloverRecipients[pactId].push(recipient);
        }
        unallocatedPool[pactId] = 0;
        rolloverReserve[pactId] = available;
        rolloverDeadline[pactId] = deadline;
        rolloverState[pactId] = ROLLOVER_LOCKED;
        emit RolloverReservedV6(pactId, available, deadline, count);
    }

    /// @notice Atomically moves a locked source reserve into the destination Pact pool and
    /// credits every source member's rollover principal at the destination. Strictly internal
    /// bookkeeping: no token leaves the vault.
    function moveRolloverReserve(uint256 sourcePactId, uint256 destinationPactId)
        external onlyRegistry nonReentrant returns (uint256 amount)
    {
        if (rolloverState[sourcePactId] != ROLLOVER_LOCKED || sourcePactId == destinationPactId
            || block.timestamp > rolloverDeadline[sourcePactId]) {
            revert RolloverUnavailable();
        }
        amount = rolloverReserve[sourcePactId];
        if (amount == 0) revert RolloverUnavailable();

        rolloverReserve[sourcePactId] = 0;
        rolloverState[sourcePactId] = ROLLOVER_MOVED;
        unallocatedPool[destinationPactId] += amount;

        address[] storage recipients = rolloverRecipients[sourcePactId];
        for (uint256 i; i < recipients.length; ++i) {
            address recipient = recipients[i];
            uint256 entitlement = rolloverEntitlement[sourcePactId][recipient];
            rolloverEntitlement[sourcePactId][recipient] = 0;
            rolloverPrincipal[destinationPactId][recipient] += entitlement;
        }
        emit RolloverConsumedV6(sourcePactId, destinationPactId, amount);
    }

    /// @notice Converts a still-locked reserve into per-member refund claims after the registry
    /// recorded a rejection or the opt-in window expired. A reserve can be released only once
    /// and a moved reserve can never be claimed again.
    function releaseRolloverReserve(uint256 pactId) external onlyRegistry nonReentrant {
        if (rolloverState[pactId] != ROLLOVER_LOCKED) revert RolloverUnavailable();
        uint256 amount = rolloverReserve[pactId];
        rolloverReserve[pactId] = 0;
        rolloverState[pactId] = ROLLOVER_RELEASED;

        address[] storage recipients = rolloverRecipients[pactId];
        for (uint256 i; i < recipients.length; ++i) {
            address recipient = recipients[i];
            uint256 entitlement = rolloverEntitlement[pactId][recipient];
            rolloverEntitlement[pactId][recipient] = 0;
            claimable[pactId][recipient] += entitlement;
        }
        emit RolloverReleasedV6(pactId, amount, recipients.length);
    }

    // ---------------------------------------------------------------------
    // Internal accounting
    // ---------------------------------------------------------------------

    function _credit(uint256 pactId, address recipient, uint256 amount) private {
        if (recipient == address(0) || amount == 0 || amount > unallocatedPool[pactId]) {
            revert InvalidSettlement();
        }
        unallocatedPool[pactId] -= amount;
        claimable[pactId][recipient] += amount;
    }

    /// @dev floor((amount - principal) * commissionBps / BPS) above the principal, else zero.
    function _commissionOn(uint256 amount, uint256 principal) private view returns (uint256) {
        return amount > principal ? (amount - principal) * commissionBps / BPS : 0;
    }

    function _claim(uint256 pactId, address recipient) private returns (uint256 amount) {
        amount = claimable[pactId][recipient];
        if (amount == 0) revert NothingToClaim();
        claimable[pactId][recipient] = 0;
        paidOut[pactId] += amount;
        _transferExact(recipient, amount);
        emit ClaimedV6(pactId, recipient, amount);
    }

    function _transferFromExact(address from, uint256 amount) private {
        uint256 beforeBalance = _balanceOf(address(this));
        _callOptionalReturn(abi.encodeCall(IPactERC20V6.transferFrom, (from, address(this), amount)));
        uint256 afterBalance = _balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert TokenAmountMismatch();
    }

    function _transferExact(address to, uint256 amount) private {
        uint256 vaultBefore = _balanceOf(address(this));
        uint256 recipientBefore = _balanceOf(to);
        _callOptionalReturn(abi.encodeCall(IPactERC20V6.transfer, (to, amount)));
        uint256 vaultAfter = _balanceOf(address(this));
        uint256 recipientAfter = _balanceOf(to);
        if (vaultAfter > vaultBefore || recipientAfter < recipientBefore
            || vaultBefore - vaultAfter != amount || recipientAfter - recipientBefore != amount) {
            revert TokenAmountMismatch();
        }
    }

    function _balanceOf(address account) private view returns (uint256 balance) {
        (bool success, bytes memory data) = stakeToken.staticcall(
            abi.encodeCall(IPactERC20V6.balanceOf, (account))
        );
        if (!success) revert TokenCallReverted(data);
        if (data.length != 32) revert TokenTransferFailed();
        balance = abi.decode(data, (uint256));
    }

    function _callOptionalReturn(bytes memory callData) private {
        (bool success, bytes memory data) = stakeToken.call(callData);
        if (!success) revert TokenCallReverted(data);
        if (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool)))) {
            revert TokenTransferFailed();
        }
    }
}
