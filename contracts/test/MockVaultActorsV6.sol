// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactVaultV6} from "../src/interfaces/IPactVaultV6.sol";
import {IPactSettlementSinkV6} from "../src/interfaces/IPactSettlementSinkV6.sol";

/// @notice Local-EVM actor used by the V6 vault tests to exercise the registry/module-only
/// guards from a contract instead of an EOA and to attempt an over-pool payout that the real
/// module can never construct (it enforces exact allocation totals).
///
/// UNAUDITED FUJI PROTOTYPE. Test-only; never deployed.
contract MockVaultActorsV6 {
    function callDeposit(IPactVaultV6 vault, uint256 pactId, address participant, uint256 amount) external {
        vault.deposit(pactId, participant, amount);
    }

    function callRelease(IPactVaultV6 vault, uint256 pactId, address participant) external {
        vault.release(pactId, participant);
    }

    function callExit(IPactVaultV6 vault, uint256 pactId, address participant, uint256 refund) external {
        vault.exit(pactId, participant, refund);
    }

    function callLockRollover(IPactVaultV6 vault, uint256 pactId, uint40 deadline, address[] calldata recipients)
        external
    {
        vault.lockRollover(pactId, deadline, recipients);
    }

    function callMoveRollover(IPactVaultV6 vault, uint256 sourcePactId, uint256 destinationPactId)
        external returns (uint256)
    {
        return vault.moveRolloverReserve(sourcePactId, destinationPactId);
    }

    function callReleaseRollover(IPactVaultV6 vault, uint256 pactId) external {
        vault.releaseRolloverReserve(pactId);
    }

    function callPayout(IPactSettlementSinkV6 vault, uint256 pactId, address recipient, uint256 amount) external {
        vault.payout(pactId, recipient, amount);
    }

    function callRefundPayout(IPactSettlementSinkV6 vault, uint256 pactId, address recipient, uint256 amount)
        external
    {
        vault.refundPayout(pactId, recipient, amount);
    }
}
