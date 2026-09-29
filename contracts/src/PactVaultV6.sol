// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PactAllocationsV6} from "./libraries/PactAllocationsV6.sol";

import {IPactERC20V6} from "./interfaces/IPactERC20V6.sol";
import {IPactSettlementSinkV6} from "./interfaces/IPactSettlementSinkV6.sol";

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
/// Access rules:
/// - `deposit`/`release`/`exit`/rollover transitions are callable only by the immutable registry.
/// - `payout`/`refundPayout`/`claimFor` are callable only by one of the two immutable modules,
///   and every credit is bounded by that Pact's `unallocatedPool`.
/// There is deliberately no owner/admin path and no arbitrary-recipient transfer.
///
/// UNAUDITED FUJI PROTOTYPE — not deployed, mainnet blocked, do not treat as production.
contract PactVaultV6 is IPactSettlementSinkV6 {
    uint256 internal constant UNLOCKED = 1;
    uint256 internal constant LOCKED = 2;

    uint8 internal constant ROLLOVER_NONE = 0;
    uint8 internal constant ROLLOVER_LOCKED = 1;
    uint8 internal constant ROLLOVER_MOVED = 2;
    uint8 internal constant ROLLOVER_RELEASED = 3;

    address public immutable stakeToken;
    address public immutable registry;
    /// @dev Walking-domain settlement module.
    address public immutable module;
    /// @dev Working-domain settlement module; zero when the working domain is not deployed.
    address public immutable workingModule;

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
    event RolloverReservedV6(uint256 indexed pactId, uint256 amount, uint40 deadline, uint256 participantCount);
    event RolloverConsumedV6(uint256 indexed sourcePactId, uint256 indexed destinationPactId, uint256 amount);
    event RolloverReleasedV6(uint256 indexed pactId, uint256 amount, uint256 participantCount);

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

    constructor(address stakeToken_, address registry_, address module_, address workingModule_) {
        // Mirrors the V5 deployment guard: the prototype refuses to exist on any network
        // other than Avalanche Fuji or a local test chain.
        if (block.chainid != 43113 && block.chainid != 31337) revert InvalidConfiguration();
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
        if (participant == address(0) || amount == 0 || contribution[pactId][participant] != 0) {
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

    /// @notice Credits a verified settlement allocation. Module-only; cannot exceed the pool.
    function payout(uint256 pactId, address recipient, uint256 amount) external onlyModule nonReentrant {
        _credit(pactId, recipient, amount);
        emit PayoutV6(pactId, recipient, amount);
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
        if (!success || data.length != 32) revert TokenTransferFailed();
        balance = abi.decode(data, (uint256));
    }

    function _callOptionalReturn(bytes memory callData) private {
        (bool success, bytes memory data) = stakeToken.call(callData);
        if (!success || (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool))))) {
            revert TokenTransferFailed();
        }
    }
}
