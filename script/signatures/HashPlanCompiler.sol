// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

/**
 * @title HashPlanCompiler
 * @notice Compiles an EIP-712 structure into the buffer and plan that MerkleAccount.sign consumes.
 * @dev Nodes form a tree flattened into an array, because Solidity cannot hold a recursive memory
 * struct. A Word field contributes its own value; every other kind contributes its hash, so it needs
 * a reserved word in its parent and a region of its own to be hashed from. Nodes form a tree: each
 * index must appear as a child at most once, since layout is recorded per index.
 */
library HashPlanCompiler {
    error EmptyStructure();

    enum Kind {
        Word, // A 32-byte field used as-is.
        Bytes, // Raw bytes hashed to one word.
        Struct, // Type hash followed by one word per field.
        Array // One word per element, with no type hash.
    }

    struct Node {
        Kind kind;
        bytes32 word; // Word: the value. Struct: the type hash.
        bytes data; // Bytes: the raw bytes.
        uint256[] children; // Struct and Array: indices into the node array.
    }

    /// @dev Where a node's own encoding lives in the compiled buffer.
    struct Region {
        uint256 offset;
        uint256 length;
    }

    /* REFERENCE */

    /// @notice Hashes the structure directly, without a buffer or a plan.
    function hashOf(Node[] memory nodes, uint256 index) internal pure returns (bytes32) {
        Node memory node = nodes[index];
        if (node.kind == Kind.Word) return node.word;
        if (node.kind == Kind.Bytes) return keccak256(node.data);

        bytes memory encoded = node.kind == Kind.Struct ? bytes.concat(node.word) : bytes("");
        for (uint256 i; i < node.children.length; ++i) {
            encoded = bytes.concat(encoded, hashOf(nodes, node.children[i]));
        }
        return keccak256(encoded);
    }

    /* IN-PLACE FORMAT */

    /**
     * @notice Compiles the fixed-length buffer and its ordered steps.
     * @dev The root struct occupies the front of the buffer so the closing step covers exactly it.
     * Every nested node is appended to a scratch area after it and collapsed into its parent's
     * reserved word. Steps are emitted deepest first, so each one reads results already written.
     */
    function compile(Node[] memory nodes, uint256 root)
        internal
        pure
        returns (bytes memory buffer, IMerkleAccount.Hash[] memory plan)
    {
        uint256 count = _stepCount(nodes, root);
        if (count == 0) revert EmptyStructure();

        Region[] memory regions = new Region[](nodes.length);
        // The root occupies the front of the buffer, so the closing step covers exactly it.
        regions[root] = Region({offset: 0, length: _regionLength(nodes, root)});
        uint256 size = _allocate(nodes, root, regions, regions[root].length);

        buffer = new bytes(size);
        plan = new IMerkleAccount.Hash[](count);
        uint256 written = _emit(nodes, root, regions, buffer, plan, 0, 0);
        // The closing step hashes the root region itself and yields the struct hash.
        plan[written] = IMerkleAccount.Hash({offset: 0, length: regions[root].length, destination: 0});
    }

    /// @dev Reserves a region for every node that contributes a hash rather than a value.
    function _allocate(Node[] memory nodes, uint256 index, Region[] memory regions, uint256 free)
        private
        pure
        returns (uint256)
    {
        Node memory node = nodes[index];
        for (uint256 i; i < node.children.length; ++i) {
            uint256 child = node.children[i];
            if (nodes[child].kind == Kind.Word) continue;
            uint256 length = _regionLength(nodes, child);
            regions[child] = Region({offset: free, length: length});
            free = _allocate(nodes, child, regions, free + length);
        }
        return free;
    }

    function _regionLength(Node[] memory nodes, uint256 index) private pure returns (uint256) {
        Node memory node = nodes[index];
        if (node.kind == Kind.Bytes) return node.data.length;
        return (node.kind == Kind.Struct ? 1 + node.children.length : node.children.length) * 32;
    }

    /// @dev Fills a node's words and appends its children's steps before its own.
    function _emit(
        Node[] memory nodes,
        uint256 index,
        Region[] memory regions,
        bytes memory buffer,
        IMerkleAccount.Hash[] memory plan,
        uint256 written,
        uint256 depth
    ) private pure returns (uint256) {
        Node memory node = nodes[index];
        uint256 base = regions[index].offset;
        uint256 slot = base;
        if (node.kind == Kind.Bytes) {
            for (uint256 i; i < node.data.length; ++i) {
                buffer[base + i] = node.data[i];
            }
            return written;
        }
        if (node.kind == Kind.Struct) {
            _writeWord(buffer, slot, node.word);
            slot += 32;
        }
        for (uint256 i; i < node.children.length; ++i) {
            uint256 child = node.children[i];
            if (nodes[child].kind == Kind.Word) {
                _writeWord(buffer, slot, nodes[child].word);
            } else {
                written = _emit(nodes, child, regions, buffer, plan, written, depth + 1);
                plan[written++] = IMerkleAccount.Hash({
                    offset: regions[child].offset, length: regions[child].length, destination: slot
                });
            }
            slot += 32;
        }
        return written;
    }

    function _stepCount(Node[] memory nodes, uint256 index) private pure returns (uint256 count) {
        Node memory node = nodes[index];
        if (node.kind == Kind.Word) return 0;
        count = 1;
        for (uint256 i; i < node.children.length; ++i) {
            count += _stepCount(nodes, node.children[i]);
        }
    }

    function _writeWord(bytes memory buffer, uint256 offset, bytes32 value) private pure {
        assembly ("memory-safe") {
            mstore(add(add(buffer, 0x20), offset), value)
        }
    }
}
