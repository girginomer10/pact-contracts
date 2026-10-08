// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactSettlementV6} from "../src/interfaces/IPactSettlementV6.sol";
import {IPactSettlementRegistryV6} from "../src/interfaces/IPactSettlementRegistryV6.sol";
import {IPactSettlementModuleV6} from "../src/interfaces/IPactSettlementModuleV6.sol";
import {IPactSettlementSinkV6} from "../src/interfaces/IPactSettlementSinkV6.sol";
import {PactTimeoutV6} from "../src/libraries/PactTimeoutV6.sol";

/// @notice Local-EVM registry stand-in for the V6 settlement module tests only. It is not a
/// Pact registry: it stores whatever terms/participants/kind the test sets and forwards
/// `settleV6`/`refundTimedOutV6` calls so the module sees its configured registry as the
/// caller. The real registry writes the terminal kind before forwarding.
contract MockPactSettlementRegistryV6 is IPactSettlementRegistryV6 {
    struct Terms {
        bytes32 termsHash;
        uint40 endAt;
        uint40 evidenceGrace;
        uint256 distributable;
    }

    bytes32 public generationId;
    /// @dev Custody pointer the real registry exposes; the module constructor reads it.
    address public vault;
    mapping(uint256 => Terms) internal termsByPact;
    mapping(uint256 => address[]) internal participantsByPact;
    mapping(uint256 => mapping(address => bool)) internal activeParticipant;
    mapping(uint256 => uint8) internal kindByPact;

    function setGenerationId(bytes32 generationId_) external {
        generationId = generationId_;
    }

    function setVault(address vault_) external {
        vault = vault_;
    }

    function setTerms(uint256 pactId, bytes32 termsHash, uint40 endAt, uint40 evidenceGrace,
        uint256 distributable) external
    {
        termsByPact[pactId] = Terms(termsHash, endAt, evidenceGrace, distributable);
    }

    function setSettlementKind(uint256 pactId, uint8 kind) external {
        kindByPact[pactId] = kind;
    }

    function setParticipants(uint256 pactId, address[] calldata participants) external {
        address[] storage current = participantsByPact[pactId];
        for (uint256 i; i < current.length; ++i) {
            activeParticipant[pactId][current[i]] = false;
        }
        delete participantsByPact[pactId];
        for (uint256 i; i < participants.length; ++i) {
            participantsByPact[pactId].push(participants[i]);
            if (participants[i] != address(0)) activeParticipant[pactId][participants[i]] = true;
        }
    }

    function pactSettlementTerms(uint256 pactId)
        external view returns (bytes32 termsHash, uint40 endAt, uint40 evidenceClosesAt,
            uint40 reviewClosesAt, uint40 settlementClosesAt, uint256 distributable,
            uint256 participantCount)
    {
        Terms storage terms = termsByPact[pactId];
        (uint40 evidence, uint40 review, uint40 settlement) =
            PactTimeoutV6.windows(terms.endAt, terms.evidenceGrace);
        return (terms.termsHash, terms.endAt, evidence, review, settlement, terms.distributable,
            participantsByPact[pactId].length);
    }

    function settlementParticipantAt(uint256 pactId, uint256 index) external view returns (address) {
        return participantsByPact[pactId][index];
    }

    function isActiveParticipant(uint256 pactId, address participant) external view returns (bool) {
        return activeParticipant[pactId][participant];
    }

    function pactSettlementKind(uint256 pactId) external view returns (uint8) {
        return kindByPact[pactId];
    }

    function callSettleV6(address module, IPactSettlementV6.SettlementAuthorization calldata authorization,
        IPactSettlementV6.Allocation[] calldata allocations, bytes calldata verifierSignature) external
    {
        IPactSettlementV6(module).settleV6(authorization, allocations, verifierSignature);
    }

    function callRefundTimedOutV6(address module, uint256 pactId) external {
        IPactSettlementModuleV6(module).refundTimedOutV6(pactId);
    }

    function callBindPactV6(address module, uint256 pactId) external {
        IPactSettlementModuleV6(module).bindPactV6(pactId);
    }
}

/// @notice Local-EVM custody stand-in. It enforces the same `msg.sender == module` rule the
/// real V6 vault must implement on its own side, records every credit and materializes claims
/// through `claimFor` exactly like the vault does.
contract MockPactSettlementSinkV6 is IPactSettlementSinkV6 {
    error NotModule();
    error AlreadyInitialized();
    error NothingToClaim();

    address public module;
    uint256 public payoutCallCount;
    uint256 public refundPayoutCallCount;
    uint256 public claimCallCount;
    mapping(uint256 => mapping(address => uint256)) public payoutTotal;
    mapping(uint256 => mapping(address => uint256)) public refundPayoutTotal;
    mapping(uint256 => mapping(address => uint256)) public credited;
    mapping(uint256 => mapping(address => uint256)) public claimedTotal;

    function setModule(address module_) external {
        if (module != address(0)) revert AlreadyInitialized();
        if (module_ == address(0)) revert NotModule();
        module = module_;
    }

    function payout(uint256 pactId, address recipient, uint256 amount) public virtual {
        if (msg.sender != module) revert NotModule();
        payoutCallCount += 1;
        payoutTotal[pactId][recipient] += amount;
        credited[pactId][recipient] += amount;
    }

    /// @dev Books each allocation exactly like `payout` (this stand-in charges no commission), so
    /// per-allocation counts and credits hold whichever finalize path the module takes.
    function payoutAfterCommission(uint256 pactId, IPactSettlementV6.Allocation[] calldata allocations)
        public virtual returns (uint256)
    {
        if (msg.sender != module) revert NotModule();
        for (uint256 i; i < allocations.length; ++i) {
            payout(pactId, allocations[i].recipient, allocations[i].amount);
        }
        return 0;
    }

    function refundPayout(uint256 pactId, address recipient, uint256 amount) public virtual {
        if (msg.sender != module) revert NotModule();
        refundPayoutCallCount += 1;
        refundPayoutTotal[pactId][recipient] += amount;
        credited[pactId][recipient] += amount;
    }

    function claimFor(uint256 pactId, address recipient) public virtual returns (uint256 amount) {
        if (msg.sender != module) revert NotModule();
        amount = credited[pactId][recipient];
        if (amount == 0) revert NothingToClaim();
        credited[pactId][recipient] = 0;
        claimedTotal[pactId][recipient] += amount;
        claimCallCount += 1;
    }
}

/// @notice Sink variant that tries to re-enter `claim` from inside `claimFor` once. The module
/// lock must reject the inner call and the outer claim must still complete.
contract MockReentrantPactSettlementSinkV6 is MockPactSettlementSinkV6 {
    bool public reentered;
    bytes4 public reentrySelector;
    bool internal attempted;

    function claimFor(uint256 pactId, address recipient) public override returns (uint256) {
        if (!attempted) {
            attempted = true;
            try IPactSettlementV6(module).claim(pactId) {
                reentered = true;
            } catch (bytes memory reason) {
                if (reason.length >= 4) {
                    reentrySelector = bytes4(reason);
                }
            }
        }
        return super.claimFor(pactId, recipient);
    }
}
