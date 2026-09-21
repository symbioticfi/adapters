// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LegacyHashPlanCompiler} from "script/signatures/LegacyHashPlanCompiler.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @dev The superseded splice implementation, kept only to measure the format it consumed.
contract LegacySignatureHasher {
    using Bytes for bytes;

    error InvalidRange();

    bytes32 public digest;

    function sign(bytes32 domainSeparator, bytes calldata preimage, LegacyHashPlanCompiler.Range[] calldata ranges)
        external
    {
        bytes memory data = preimage;
        for (uint256 i; i < ranges.length; ++i) {
            LegacyHashPlanCompiler.Range calldata range = ranges[i];
            if (range.start > range.end || range.end > data.length) revert InvalidRange();
            data = bytes.concat(
                data.slice(0, range.start), keccak256(data.slice(range.start, range.end)), data.slice(range.end)
            );
        }
        digest = MessageHashUtils.toTypedDataHash(domainSeparator, keccak256(data));
    }
}

/// @dev Mirrors MerkleAccount.sign so the comparison measures the hashing, not the authorization.
contract InPlaceSignatureHasher {
    error InvalidHashPlan();

    bytes32 public digest;

    function sign(bytes32 domainSeparator, bytes memory buffer, IMerkleAccount.Hash[] calldata plan) external {
        uint256 size = buffer.length;
        if (size < 32 || plan.length == 0) revert InvalidHashPlan();

        bytes32 structHash;
        for (uint256 i; i < plan.length; ++i) {
            uint256 offset = plan[i].offset;
            uint256 length = plan[i].length;
            uint256 destination = plan[i].destination;

            if (offset > size || length > size - offset || destination > size - 32) revert InvalidHashPlan();

            assembly ("memory-safe") {
                let base := add(buffer, 0x20)
                structHash := keccak256(add(base, offset), length)
                mstore(add(base, destination), structHash)
            }
        }
        digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }
}
