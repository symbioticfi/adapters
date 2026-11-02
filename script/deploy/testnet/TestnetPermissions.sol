// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

/// @title TestnetPermissions
/// @notice Builds sorted-pair proofs for exact action templates and explicit runtime masks.
library TestnetPermissions {
    function authorize(IMerkleAccount.Action[] memory actions)
        internal
        pure
        returns (bytes32 root, bytes32[] memory leaves)
    {
        uint256 size = 1;
        uint256 depth;
        while (size < actions.length) {
            size *= 2;
            ++depth;
        }
        bytes32[] memory nodes = new bytes32[](2 * size);
        leaves = new bytes32[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            leaves[i] = ActionMasker.mask(actions[i].target, actions[i].value, actions[i].data, actions[i].dataMask);
            nodes[size + i] = leaves[i];
        }
        for (uint256 i = size - 1; i > 0; --i) {
            nodes[i] = _hash(nodes[2 * i], nodes[2 * i + 1]);
        }
        root = nodes[1];
        for (uint256 i; i < actions.length; ++i) {
            actions[i].proof = new bytes32[](depth);
            uint256 node = size + i;
            for (uint256 j; j < depth; ++j) {
                actions[i].proof[j] = nodes[node ^ 1];
                node /= 2;
            }
        }
    }

    function action(address target, bytes memory data, uint256 maskOffset)
        internal
        pure
        returns (IMerkleAccount.Action memory value)
    {
        bytes memory mask = new bytes(data.length);
        if (maskOffset > 0) {
            for (uint256 i; i < 32; ++i) {
                mask[maskOffset + i] = 0xff;
            }
        }
        value = IMerkleAccount.Action({target: target, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }

    function _hash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
