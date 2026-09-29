// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactSettlementV6} from "../interfaces/IPactSettlementV6.sol";

/// @notice Pure validation used by the V6 settlement module before any claimable balance is
/// written. Keeping this outside the registry is deliberate: V5 is already at EIP-170 size.
library PactAllocationsV6 {
    error EmptyAllocations();
    error TooManyAllocations();
    error InvalidRecipient();
    error InvalidAmount();
    error DuplicateRecipient();
    error AllocationTotalMismatch();

    uint256 internal constant MAX_PARTICIPANTS = 20;

    /// Canonical numeric wallet order for equal-share dust. The caller retains its own
    /// recipient validation; this bounded insertion sort never uses the swap-pop roster.
    function sortAddresses(address[] memory members) internal pure returns (address[] memory) {
        for (uint256 i = 1; i < members.length; ++i) {
            address member = members[i];
            uint256 j = i;
            while (j > 0 && uint160(members[j - 1]) > uint160(member)) {
                members[j] = members[j - 1];
                --j;
            }
            members[j] = member;
        }
        return members;
    }

    function validate(IPactSettlementV6.Allocation[] calldata allocations, uint256 distributable)
        internal pure returns (bytes32 allocationsHash)
    {
        uint256 length = allocations.length;
        if (length == 0) revert EmptyAllocations();
        if (length > MAX_PARTICIPANTS) revert TooManyAllocations();

        uint256 total;
        for (uint256 i; i < length; ++i) {
            address recipient = allocations[i].recipient;
            uint256 amount = allocations[i].amount;
            if (recipient == address(0)) revert InvalidRecipient();
            if (amount == 0) revert InvalidAmount();
            total += amount;
            for (uint256 j; j < i; ++j) {
                if (allocations[j].recipient == recipient) revert DuplicateRecipient();
            }
        }
        if (total != distributable) revert AllocationTotalMismatch();
        return keccak256(abi.encode(allocations));
    }
}
