// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Registry-facing custody surface of the gem-generation vault. The registry
/// orchestrates joins, leaves, exits and cancellation credits; the vault is the single source
/// of every account (`unallocatedPool`, `claimable`, `paidOut`, `deposited`). There is no
/// rollover and no commission in the gem generation.
///
/// UNAUDITED FUJI-ONLY PROTOTYPE. Do not treat as production.
interface IPactGemVaultV6 {
    function stakeToken() external view returns (address);

    function registry() external view returns (address);

    /// @dev Number of settlement modules fixed at construction (one per registry domain).
    function moduleCount() external view returns (uint256);

    function moduleAt(uint256 index) external view returns (address);

    function isModule(address candidate) external view returns (bool);

    function pool(uint256 pactId) external view returns (uint256);

    function principalOf(uint256 pactId, address participant) external view returns (uint256);

    /// @notice Pulls exactly `amount` from `participant` into this vault and credits the Pact pool.
    function deposit(uint256 pactId, address participant, uint256 amount) external;

    /// @notice Full refund credit for a still-recruiting leaver or a cancelled Pact member.
    function release(uint256 pactId, address participant) external;

    /// @notice Credits `refund` of the participant's principal as a claim; the penalty stays in
    /// the Pact pool for final settlement.
    function exit(uint256 pactId, address participant, uint256 refund) external;
}
