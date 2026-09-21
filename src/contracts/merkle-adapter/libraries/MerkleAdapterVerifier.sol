// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMerkleAccount} from "../../../interfaces/merkle-adapter/IMerkleAccount.sol";

/**
 * @title MerkleAdapterVerifier
 * @notice Library for hashing masked Merkle actions into canonical leaves.
 */
library MerkleAdapterVerifier {
    /* INTERNAL FUNCTIONS */

    /**
     * @dev Constructs the canonical double-hashed leaf, committing the mask alongside the masked calldata.
     * Both are caller-supplied, so committing only the masked result would authorize every `data` that
     * is a bitwise superset of it: a caller can pass `dataMask = ~maskedData`, which leaves the leaf's
     * zero bits unconstrained. A mask must pin a bit to zero as firmly as it pins one to one.
     */
    function leaf(address target, uint96 value, bytes memory data, bytes memory dataMask)
        internal
        pure
        returns (bytes32)
    {
        if (data.length != dataMask.length) revert IMerkleAccount.InvalidDataMaskLength();

        bytes memory maskedData = new bytes(data.length);
        // Bytes allocations are padded to whole words; hashing below excludes the trailing padding.
        assembly ("memory-safe") {
            for { let i := 32 } lt(i, add(mload(data), 32)) { i := add(i, 32) } {
                mstore(add(maskedData, i), and(mload(add(data, i)), not(mload(add(dataMask, i)))))
            }
        }
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        target, value == 0 ? bytes1(0) : bytes1(0xff), keccak256(dataMask), keccak256(maskedData)
                    )
                )
            )
        );
    }
}
