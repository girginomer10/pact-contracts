// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactERC20V6} from "./interfaces/IPactERC20V6.sol";
import {IPactGemVaultV6} from "./interfaces/IPactGemVaultV6.sol";
import {IPactSettlementSinkV6} from "./interfaces/IPactSettlementSinkV6.sol";
import {IPactSettlementV6} from "./interfaces/IPactSettlementV6.sol";

/// @title PactGemVaultV6
/// @notice Single-source stake accounting for the gem generation. It is the V6 vault without
/// rollover and without commission, shared by up to four domain modules (Walking, Working,
/// Proof, ...), each fixed at construction.
///
/// Accounting model (one ledger per Pact, no second source anywhere):
/// - `unallocatedPool[pactId]`   custody still owned by the Pact pool
/// - `claimable[pactId][who]`    credits already earned, not yet transferred
/// - `paidOut[pactId]`           cumulative value actually transferred out by claims
/// - `deposited[pactId]`         cumulative value pulled in by deposits
///
/// Allocation, cancellation and exit move value from `unallocatedPool` into `claimable`, and
/// `claim` consumes exactly the caller's credit before the token transfer. Per Pact,
/// `deposited == unallocatedPool + SUM(claimable) + paidOut`; system-wide,
/// `tokenBalance + SUM(paidOut) == SUM(deposited)` (strict for the gem token, which cannot be
/// donated to the vault).
///
/// Commission: none, by construction. `commissionBps` is the constant 0 and
/// `payoutAfterCommission` credits every allocation in full, so the module surface is kept
/// unchanged while the pool stays exactly conserved.
///
/// Access rules:
/// - `deposit`/`release`/`exit` are callable only by the immutable registry.
/// - `payout`/`payoutAfterCommission`/`refundPayout`/`claimFor` are callable only by one of the
///   construction-time modules, and every credit is bounded by that Pact's `unallocatedPool`.
/// - `claim`/`claimTo` are permissionless, but each only ever pays the address whose credit it
///   consumes.
/// There is deliberately no owner/admin path and no arbitrary-recipient transfer.
///
/// UNAUDITED FUJI-ONLY PROTOTYPE. The constructor refuses every chain except Avalanche Fuji
/// (43113) and the local test chain (31337). Never represent this as production-safe.
contract PactGemVaultV6 is IPactGemVaultV6, IPactSettlementSinkV6 {
    uint256 internal constant UNLOCKED = 1;
    uint256 internal constant LOCKED = 2;
    uint256 public constant MAX_MODULES = 4;
    /// @dev The gem generation never takes a commission.
    uint16 public constant commissionBps = 0;

    address public immutable stakeToken;
    address public immutable registry;
    uint256 public immutable moduleCount;
    address internal immutable module0;
    address internal immutable module1;
    address internal immutable module2;
    address internal immutable module3;

    mapping(uint256 pactId => uint256 amount) public unallocatedPool;
    mapping(uint256 pactId => mapping(address participant => uint256 amount)) public claimable;
    mapping(uint256 pactId => uint256 amount) public paidOut;
    mapping(uint256 pactId => uint256 amount) public deposited;
    mapping(uint256 pactId => mapping(address participant => uint256 amount)) public contribution;

    uint256 internal locked = UNLOCKED;

    error OnlyRegistry();
    error OnlyModule();
    error InvalidConfiguration();
    error InvalidSettlement();
    error NothingToClaim();
    error TokenTransferFailed();
    /// @dev The stake token reverted; `reason` is its raw revert data, wrapped so token data can
    /// never impersonate a Pact contract error.
    error TokenCallReverted(bytes reason);
    error TokenAmountMismatch();
    error Reentrancy();

    event ContributionLockedV6(uint256 indexed pactId, address indexed participant, uint256 amount);
    event ContributionReleasedV6(uint256 indexed pactId, address indexed participant, uint256 amount);
    event ExitCreditedV6(uint256 indexed pactId, address indexed participant, uint256 principal,
        uint256 refund, uint256 penalty);
    event PayoutV6(uint256 indexed pactId, address indexed recipient, uint256 amount);
    event RefundPayoutV6(uint256 indexed pactId, address indexed recipient, uint256 amount);
    event ClaimedV6(uint256 indexed pactId, address indexed recipient, uint256 amount);
    event ClaimedForV6(uint256 indexed pactId, address indexed caller, address indexed recipient, uint256 amount);

    modifier onlyRegistry() {
        if (msg.sender != registry) revert OnlyRegistry();
        _;
    }

    modifier onlyModule() {
        if (!isModule(msg.sender)) revert OnlyModule();
        _;
    }

    modifier nonReentrant() {
        if (locked != UNLOCKED) revert Reentrancy();
        locked = LOCKED;
        _;
        locked = UNLOCKED;
    }

    /// @param modules_ the domain modules in registry domain order (CREATE-predicted: they are
    /// deployed after the registry, which is deployed after this vault).
    constructor(address stakeToken_, address registry_, address[] memory modules_) {
        if (block.chainid != 43113 && block.chainid != 31337) revert InvalidConfiguration();
        uint256 count = modules_.length;
        if (stakeToken_ == address(0) || stakeToken_.code.length == 0 || registry_ == address(0)
            || registry_ == stakeToken_ || count == 0 || count > MAX_MODULES) {
            revert InvalidConfiguration();
        }
        for (uint256 i; i < count; ++i) {
            address candidate = modules_[i];
            if (candidate == address(0) || candidate == stakeToken_ || candidate == registry_
                || candidate == address(this)) {
                revert InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (modules_[j] == candidate) revert InvalidConfiguration();
            }
        }
        // A gem token (anything answering `vault()`) must have been built for this exact vault, so
        // a wrong CREATE prediction fails here instead of making every deposit revert later.
        (bool answered, bytes memory pinned) = stakeToken_.staticcall(abi.encodeWithSignature("vault()"));
        if (answered && pinned.length == 32 && abi.decode(pinned, (address)) != address(this)) {
            revert InvalidConfiguration();
        }
        stakeToken = stakeToken_;
        registry = registry_;
        moduleCount = count;
        module0 = modules_[0];
        module1 = count > 1 ? modules_[1] : address(0);
        module2 = count > 2 ? modules_[2] : address(0);
        module3 = count > 3 ? modules_[3] : address(0);
    }

    function moduleAt(uint256 index) public view returns (address) {
        if (index >= moduleCount) revert InvalidConfiguration();
        if (index == 0) return module0;
        if (index == 1) return module1;
        if (index == 2) return module2;
        return module3;
    }

    function isModule(address candidate) public view returns (bool) {
        return candidate != address(0)
            && (candidate == module0 || candidate == module1 || candidate == module2 || candidate == module3);
    }

    /// @notice Unallocated-pool alias kept for the registry/artifact surface.
    function pool(uint256 pactId) external view returns (uint256) {
        return unallocatedPool[pactId];
    }

    /// @notice Principal a participant exits with: its contribution (no rollover exists).
    function principalOf(uint256 pactId, address participant) external view returns (uint256) {
        return contribution[pactId][participant];
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

    /// @notice Returns a participant's full principal as a claim (recruiting leave, cancellation
    /// or the pre-start collapse). The registry removes the participant in the same transaction.
    function release(uint256 pactId, address participant) external onlyRegistry nonReentrant {
        uint256 principal = contribution[pactId][participant];
        if (principal == 0 || principal > unallocatedPool[pactId]) revert InvalidSettlement();
        contribution[pactId][participant] = 0;
        unallocatedPool[pactId] -= principal;
        claimable[pactId][participant] += principal;
        emit ContributionReleasedV6(pactId, participant, principal);
    }

    /// @notice Credits a post-start exit: `refund` becomes a claim and the penalty stays in the
    /// Pact pool for the final settlement. The whole principal is consumed, so a second exit can
    /// never double-credit.
    function exit(uint256 pactId, address participant, uint256 refund) external onlyRegistry nonReentrant {
        uint256 principal = contribution[pactId][participant];
        if (principal == 0 || refund > principal || refund > unallocatedPool[pactId]) {
            revert InvalidSettlement();
        }
        contribution[pactId][participant] = 0;
        unallocatedPool[pactId] -= refund;
        if (refund != 0) claimable[pactId][participant] += refund;
        emit ExitCreditedV6(pactId, participant, principal, refund, principal - refund);
    }

    /// @notice Credits a verified settlement allocation in full. Module-only; cannot exceed the pool.
    function payout(uint256 pactId, address recipient, uint256 amount) external onlyModule nonReentrant {
        _credit(pactId, recipient, amount);
        emit PayoutV6(pactId, recipient, amount);
    }

    /// @notice Same as `payout` for every allocation: the gem generation takes no commission.
    /// Kept so the shared settlement module can finalize any split. Module-only; the module has
    /// already proven the allocations hash to the signed value, and every credit is bounded by
    /// the pool. Always returns 0.
    function payoutAfterCommission(uint256 pactId, IPactSettlementV6.Allocation[] calldata allocations)
        external onlyModule nonReentrant returns (uint256 commission)
    {
        for (uint256 i; i < allocations.length; ++i) {
            _credit(pactId, allocations[i].recipient, allocations[i].amount);
            emit PayoutV6(pactId, allocations[i].recipient, allocations[i].amount);
        }
        return 0;
    }

    /// @notice Always 0: kept for client parity with the commission vault.
    function commissionOn(uint256, address, uint256) external pure returns (uint256) {
        return 0;
    }

    /// @notice Credits a registry-gated timeout refund or a veto split. Module-only.
    function refundPayout(uint256 pactId, address recipient, uint256 amount) external onlyModule nonReentrant {
        _credit(pactId, recipient, amount);
        emit RefundPayoutV6(pactId, recipient, amount);
    }

    /// @dev Module-side claim entry. The module always passes its own `msg.sender`.
    function claimFor(uint256 pactId, address recipient) external onlyModule nonReentrant returns (uint256 amount) {
        amount = _claim(pactId, recipient);
    }

    function claim(uint256 pactId) external nonReentrant returns (uint256 amount) {
        amount = _claim(pactId, msg.sender);
    }

    /// @notice Permissionless payout of `recipient`'s own credit to `recipient` only (keeper).
    function claimTo(uint256 pactId, address recipient) external nonReentrant returns (uint256 amount) {
        amount = _claim(pactId, recipient);
        emit ClaimedForV6(pactId, msg.sender, recipient, amount);
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
