// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Registry-facing custody surface of the V6 vault. The registry orchestrates joins,
/// exits, cancellation credits and rollover links; the vault is the single source of every
/// monetary account (`unallocatedPool`, `rolloverReserve`, `claimable`, `paidOut`).
///
/// The vault is shared by the walking and working domains. Both module addresses are fixed at
/// construction (the working one may be zero when that domain is not deployed yet); every
/// payout is still bounded by the individual Pact pool and no caller can choose a recipient.
///
/// UNAUDITED FUJI PROTOTYPE. Do not treat as production.
interface IPactVaultV6 {
    function stakeToken() external view returns (address);

    function registry() external view returns (address);

    /// @dev Walking-domain settlement module.
    function module() external view returns (address);

    /// @dev Working-domain settlement module; zero when the working domain is not deployed.
    function workingModule() external view returns (address);

    /// @notice Unallocated custody still owned by the Pact pool. Alias of `unallocatedPool`.
    function pool(uint256 pactId) external view returns (uint256);

    function unallocatedPool(uint256 pactId) external view returns (uint256);

    function rolloverReserve(uint256 pactId) external view returns (uint256);

    function claimable(uint256 pactId, address participant) external view returns (uint256);

    function paidOut(uint256 pactId) external view returns (uint256);

    function contribution(uint256 pactId, address participant) external view returns (uint256);

    function rolloverPrincipal(uint256 pactId, address participant) external view returns (uint256);

    /// @notice Principal a participant can exit with: cash contribution + credited rollover.
    function principalOf(uint256 pactId, address participant) external view returns (uint256);

    /// @dev 0 = none, 1 = locked, 2 = moved to a destination Pact, 3 = released as refunds.
    function rolloverState(uint256 pactId) external view returns (uint8);

    function rolloverEntitlement(uint256 pactId, address participant) external view returns (uint256);

    function rolloverRecipientCount(uint256 pactId) external view returns (uint256);

    /// @notice Pulls exactly `amount` from `participant` into this vault and credits the Pact pool.
    function deposit(uint256 pactId, address participant, uint256 amount) external;

    /// @notice Full refund credit for a still-recruiting leaver; the participant claims it later.
    function release(uint256 pactId, address participant) external;

    /// @notice Credits `refund` of the participant's principal as a claim; the penalty stays in
    /// the Pact pool for final settlement.
    function exit(uint256 pactId, address participant, uint256 refund) external;

    /// @notice Moves the whole pool into `rolloverReserve` with deterministic equal entitlements.
    function lockRollover(uint256 pactId, uint40 deadline, address[] calldata recipients) external;

    /// @notice Atomically moves a source reserve into a destination Pact pool and credits every
    /// recipient's rollover principal. Registry-only.
    function moveRolloverReserve(uint256 sourcePactId, uint256 destinationPactId)
        external returns (uint256 amount);

    /// @notice Converts a still-locked reserve into per-member refund claims. Registry-only;
    /// the registry owns the rejection/expiry decision.
    function releaseRolloverReserve(uint256 pactId) external;
}
