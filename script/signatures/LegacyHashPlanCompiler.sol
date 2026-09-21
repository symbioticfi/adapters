// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {HashPlanCompiler} from "./HashPlanCompiler.sol";

/**
 * @title LegacyHashPlanCompiler
 * @notice Compiles the same structure into the superseded splice format, for comparison.
 * @dev The superseded format replaced a byte range with its hash, so the preimage changed length
 * after every range and later ranges referred to the already-shortened buffer. The compiler
 * therefore has to model the buffer as it shrinks, which the fixed-length format removes entirely.
 */
library LegacyHashPlanCompiler {
    error EmptyStructure();

    /// @notice A range of the current preimage, replaced by its hash.
    struct Range {
        uint256 start;
        uint256 end;
    }

    /**
     * @dev A recorded replacement, spanning [start, start + length) of the original preimage.
     * `reduction` is the length actually removed when it ran, which is not `length - 32`: a nested
     * replacement has already shrunk this span, and a field shorter than a word grows it instead.
     */
    struct Splice {
        uint256 start;
        uint256 length;
        int256 reduction;
    }

    struct Layout {
        uint256[] starts;
        uint256[] lengths;
        Splice[] splices;
        uint256 spliced;
        Range[] ranges;
        uint256 emitted;
    }

    /**
     * @notice Compiles the fully inlined preimage and its ordered ranges.
     * @dev The root needs no range: the superseded implementation hashed whatever remained.
     */
    function compile(HashPlanCompiler.Node[] memory nodes, uint256 root)
        internal
        pure
        returns (bytes memory preimage, Range[] memory ranges)
    {
        if (nodes[root].kind == HashPlanCompiler.Kind.Word) revert EmptyStructure();

        Layout memory layout = Layout({
            starts: new uint256[](nodes.length),
            lengths: new uint256[](nodes.length),
            splices: new Splice[](nodes.length),
            spliced: 0,
            ranges: new Range[](_rangeCount(nodes, root)),
            emitted: 0
        });

        _measure(nodes, root, layout);
        _place(nodes, root, layout, 0);
        preimage = new bytes(layout.lengths[root]);
        _write(nodes, root, layout, preimage);
        _emit(nodes, root, layout, true);
        ranges = layout.ranges;
    }

    /* PRIVATE FUNCTIONS */

    function _measure(HashPlanCompiler.Node[] memory nodes, uint256 index, Layout memory layout)
        private
        pure
        returns (uint256 length)
    {
        HashPlanCompiler.Node memory node = nodes[index];
        if (node.kind == HashPlanCompiler.Kind.Word) {
            length = 32;
        } else if (node.kind == HashPlanCompiler.Kind.Bytes) {
            length = node.data.length;
        } else {
            length = node.kind == HashPlanCompiler.Kind.Struct ? 32 : 0;
            for (uint256 i; i < node.children.length; ++i) {
                length += _measure(nodes, node.children[i], layout);
            }
        }
        layout.lengths[index] = length;
    }

    function _place(HashPlanCompiler.Node[] memory nodes, uint256 index, Layout memory layout, uint256 offset)
        private
        pure
    {
        layout.starts[index] = offset;
        HashPlanCompiler.Node memory node = nodes[index];
        if (node.kind == HashPlanCompiler.Kind.Struct) offset += 32;
        for (uint256 i; i < node.children.length; ++i) {
            _place(nodes, node.children[i], layout, offset);
            offset += layout.lengths[node.children[i]];
        }
    }

    function _write(HashPlanCompiler.Node[] memory nodes, uint256 index, Layout memory layout, bytes memory preimage)
        private
        pure
    {
        HashPlanCompiler.Node memory node = nodes[index];
        uint256 start = layout.starts[index];
        if (node.kind == HashPlanCompiler.Kind.Bytes) {
            for (uint256 i; i < node.data.length; ++i) {
                preimage[start + i] = node.data[i];
            }
            return;
        }
        if (node.kind == HashPlanCompiler.Kind.Word) {
            _writeWord(preimage, start, node.word);
            return;
        }
        if (node.kind == HashPlanCompiler.Kind.Struct) _writeWord(preimage, start, node.word);
        for (uint256 i; i < node.children.length; ++i) {
            _write(nodes, node.children[i], layout, preimage);
        }
    }

    /// @dev Post-order, so a parent's range is measured after its children have already collapsed.
    function _emit(HashPlanCompiler.Node[] memory nodes, uint256 index, Layout memory layout, bool isRoot)
        private
        pure
    {
        HashPlanCompiler.Node memory node = nodes[index];
        if (node.kind == HashPlanCompiler.Kind.Word) return;
        for (uint256 i; i < node.children.length; ++i) {
            _emit(nodes, node.children[i], layout, false);
        }
        if (isRoot) return;

        uint256 start = layout.starts[index];
        uint256 length = layout.lengths[index];
        uint256 from = _current(layout, start);
        uint256 to = _current(layout, start + length);
        layout.ranges[layout.emitted++] = Range({start: from, end: to});
        layout.splices[layout.spliced++] = Splice({start: start, length: length, reduction: int256(to - from) - 32});
    }

    /**
     * @dev Maps an original offset onto the buffer as it stands after every recorded replacement.
     * Only a replacement lying entirely before the offset moves it, so a parent keeps its own start
     * while its children pull in its end, and a zero-length field still displaces the field after it.
     */
    function _current(Layout memory layout, uint256 offset) private pure returns (uint256) {
        int256 shifted = int256(offset);
        for (uint256 i; i < layout.spliced; ++i) {
            if (layout.splices[i].start + layout.splices[i].length <= offset) {
                shifted -= layout.splices[i].reduction;
            }
        }
        return uint256(shifted);
    }

    function _rangeCount(HashPlanCompiler.Node[] memory nodes, uint256 index) private pure returns (uint256 count) {
        HashPlanCompiler.Node memory node = nodes[index];
        if (node.kind == HashPlanCompiler.Kind.Word) return 0;
        for (uint256 i; i < node.children.length; ++i) {
            count += _rangeCount(nodes, node.children[i])
            + (nodes[node.children[i]].kind == HashPlanCompiler.Kind.Word ? 0 : 1);
        }
    }

    function _writeWord(bytes memory preimage, uint256 offset, bytes32 value) private pure {
        assembly ("memory-safe") {
            mstore(add(add(preimage, 0x20), offset), value)
        }
    }
}
