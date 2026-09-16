// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {IMerkleAdapter} from "../../../interfaces/IMerkleAdapter.sol";

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title MerkleAdapterVerifier
 * @notice Library for hashing masked Merkle actions and verifying sorted Merkle proofs.
 */
library MerkleAdapterVerifier {
    /* INTERNAL FUNCTIONS */

    /**
     * @dev Applies each calldata mask byte to the corresponding data byte.
     */
    function maskData(bytes calldata data, bytes calldata dataMask) internal pure returns (bytes memory maskedData) {
        if (data.length != dataMask.length) revert IMerkleAdapter.InvalidDataMaskLength();

        maskedData = new bytes(data.length);
        for (uint256 i; i < data.length; ++i) {
            maskedData[i] = data[i] & dataMask[i];
        }
    }

    /**
     * @dev Constructs the canonical double-hashed leaf, committing the mask alongside the masked calldata.
     * Both are caller-supplied, so committing only the masked result would authorize every `data` that
     * is a bitwise superset of it: a caller can pass `dataMask = maskedData`, which leaves the leaf's
     * zero bits unconstrained. A mask must pin a bit to zero as firmly as it pins one to one.
     */
    function leaf(address target, uint96 value, bytes calldata data, bytes calldata dataMask)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            bytes.concat(keccak256(abi.encode(target, value, keccak256(dataMask), keccak256(maskData(data, dataMask)))))
        );
    }

    /**
     * @dev Verifies the derived action leaf, which also serves as its access-control role.
     */
    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leafHash) internal pure returns (bool) {
        return MerkleProof.verifyCalldata(proof, root, leafHash);
    }
}
