// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local-EVM EIP-1271 verifier stand-in for the V6 module tests: a contract signer
/// that accepts exactly the signatures of one configured EOA, with a switch to answer wrongly
/// so the module's magic-value check can be exercised.
///
/// UNAUDITED FUJI PROTOTYPE. Test-only; never deployed.
contract MockERC1271VerifierV6 {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    address public immutable owner;
    bool public broken;

    constructor(address owner_) {
        owner = owner_;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        if (broken || signature.length != 65) return bytes4(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        return ecrecover(digest, v, r, s) == owner ? MAGIC : bytes4(0);
    }
}
