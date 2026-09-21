// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {HashPlanCompiler} from "script/signatures/HashPlanCompiler.sol";
import {LegacyHashPlanCompiler} from "script/signatures/LegacyHashPlanCompiler.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {InPlaceSignatureHasher, LegacySignatureHasher} from "test/mocks/SignatureHashers.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Test, console} from "forge-std/Test.sol";

/// @dev Both compilers take the same structure, so any difference is the format, not the input.
contract HashPlanCompilersTest is Test {
    using HashPlanCompiler for HashPlanCompiler.Node[];

    bytes32 internal constant DOMAIN = keccak256("domain");

    InPlaceSignatureHasher internal inPlace = new InPlaceSignatureHasher();
    LegacySignatureHasher internal legacy = new LegacySignatureHasher();

    function test_BothFormatsAgreeOnFlatStruct() public {
        _compare("flat struct", _flat(3));
    }

    function test_BothFormatsAgreeOnNestedArray() public {
        _compare("Batch(Item[],uint256)", _batch());
    }

    function test_BothFormatsAgreeOnDynamicFields() public {
        _compare("Message(bytes,bytes)", _message(hex"aabbcc", hex""));
    }

    /// @dev CoW's Order is twelve static fields; appData is already a hash, so nothing nests.
    function test_RealShapeCoWOrder() public {
        _compare("CoW Order(12 flat fields)", _flat(12));
    }

    /// @dev Liquid Lane's Request carries an Output[], so it nests two levels.
    function test_RealShapeLiquidLaneRequest() public {
        _compare("LiquidLane Request(Output[])", _liquidLaneRequest());
    }

    function test_BothFormatsAgreeOnDeepNesting() public {
        _compare("depth 4 struct chain", _chain(4));
    }

    function testFuzz_BothFormatsAgreeOnDynamicFields(bytes memory first, bytes memory second) public {
        vm.assume(first.length < 256 && second.length < 256);
        _compare("", _message(first, second));
    }

    function testFuzz_BothFormatsAgreeOnAnyWidth(uint8 fields) public {
        _compare("", _flat(uint256(bound(fields, 1, 12))));
    }

    /**
     * @dev A leaf pins bytes at fixed calldata offsets, so a field is only pinnable when its
     * position does not move with someone else's value. Shape: Struct{Word a, bytes payload, Word b},
     * compiled at two payload lengths, asking where the trailing word b ends up.
     */
    function test_LeafPinnabilityUnderVariableLength() public pure {
        bytes32 b = bytes32(uint256(0xbb));
        (bytes memory shortBuffer, IMerkleAccount.Hash[] memory shortPlan) = HashPlanCompiler.compile(_payload(32), 3);
        (bytes memory longBuffer, IMerkleAccount.Hash[] memory longPlan) = HashPlanCompiler.compile(_payload(96), 3);
        (bytes memory shortPre, LegacyHashPlanCompiler.Range[] memory shortRanges) =
            LegacyHashPlanCompiler.compile(_payload(32), 3);
        (bytes memory longPre, LegacyHashPlanCompiler.Range[] memory longRanges) =
            LegacyHashPlanCompiler.compile(_payload(96), 3);

        // In-place: b keeps word 3 of the struct region whatever the payload does, so it is pinnable.
        assertEq(_wordAt(shortBuffer, 96), b, "in-place b at 96");
        assertEq(_wordAt(longBuffer, 96), b, "in-place b still at 96");
        // Only the payload step's length moves; its offset, its destination and the closing step hold.
        assertEq(shortPlan[0].offset, longPlan[0].offset, "payload step offset");
        assertEq(shortPlan[0].destination, longPlan[0].destination, "payload step destination");
        assertEq(shortPlan[1].offset, longPlan[1].offset, "closing step offset");
        assertEq(shortPlan[1].length, longPlan[1].length, "closing step length");
        assertTrue(shortPlan[0].length != longPlan[0].length, "only the payload length varies");

        // Legacy: the payload is inlined, so b slides and no fixed mask can pin it.
        // The payload is inlined at 64, straight after the type hash and a, so b sits at 64 + length.
        assertEq(_wordAt(shortPre, 96), b, "legacy b at 96");
        assertEq(_wordAt(longPre, 160), b, "legacy b moved to 160");
        assertTrue(_wordAt(longPre, 96) != b, "legacy b no longer at 96");
        // And the range covering the payload moves with it.
        assertTrue(shortRanges[0].end != longRanges[0].end, "legacy range end varies");

        console.log("in-place: b offset short/long", 96, 96);
        console.log("legacy:   b offset short/long", 96, 160);
        console.log("in-place plan words that vary", uint256(1));
        console.log("legacy   plan words that vary", uint256(1));
    }

    function _wordAt(bytes memory data, uint256 offset) internal pure returns (bytes32 word) {
        assembly ("memory-safe") {
            word := mload(add(add(data, 0x20), offset))
        }
    }

    /// @dev Struct{Word a, bytes payload, Word b} with a payload of the requested length.
    function _payload(uint256 length) internal pure returns (HashPlanCompiler.Node[] memory nodes) {
        bytes memory filled = new bytes(length);
        for (uint256 i; i < length; ++i) {
            filled[i] = 0x11;
        }
        nodes = new HashPlanCompiler.Node[](4);
        nodes[0] = _word(bytes32(uint256(0xaa)));
        nodes[1] = _bytes(filled);
        nodes[2] = _word(bytes32(uint256(0xbb)));
        nodes[3] = _parent(HashPlanCompiler.Kind.Struct, keccak256("Payload"), _indices(0, 3));
    }

    /**
     * @dev Sign logs the domain separator and the buffer as supplied, so the whole signed message
     * is derivable from the event: replay the plan over the logged buffer and rewrap it.
     */
    function test_EventAloneDerivesTheSignedMessage() public pure {
        (bytes memory buffer, IMerkleAccount.Hash[] memory plan) = HashPlanCompiler.compile(_batch(), 6);
        bytes32 domainSeparator = keccak256("some protocol domain");

        // Everything below uses only what Sign carries: domainSeparator, buffer and plan.
        bytes memory replayed = bytes.concat(buffer);
        bytes32 structHash = _apply(replayed, plan);
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);

        assertEq(digest, MessageHashUtils.toTypedDataHash(domainSeparator, HashPlanCompiler.hashOf(_batch(), 6)));
        // The type hash is still readable, so the structure identifies itself.
        assertEq(_wordAt(buffer, 0), keccak256("Batch"), "root type hash survives in the log");
    }

    /// @dev Mirrors the loop in MerkleAccount.sign so the test can observe the buffer afterwards.
    function _apply(bytes memory buffer, IMerkleAccount.Hash[] memory plan) internal pure returns (bytes32 hash) {
        for (uint256 i; i < plan.length; ++i) {
            uint256 offset = plan[i].offset;
            uint256 length = plan[i].length;
            uint256 destination = plan[i].destination;
            assembly ("memory-safe") {
                let base := add(buffer, 0x20)
                hash := keccak256(add(base, offset), length)
                mstore(add(base, destination), hash)
            }
        }
    }

    function _writeWord(bytes memory data, uint256 offset, bytes32 value) internal pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 0x20), offset), value)
        }
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Compiles the same structure twice, runs both, and requires the reference digest from each.
    function _compare(string memory label, HashPlanCompiler.Node[] memory nodes) internal {
        uint256 root = nodes.length - 1;
        bytes32 expected = MessageHashUtils.toTypedDataHash(DOMAIN, HashPlanCompiler.hashOf(nodes, root));

        (bytes memory buffer, IMerkleAccount.Hash[] memory plan) = HashPlanCompiler.compile(nodes, root);
        (bytes memory preimage, LegacyHashPlanCompiler.Range[] memory ranges) =
            LegacyHashPlanCompiler.compile(nodes, root);

        bytes memory inPlaceCall = abi.encodeCall(InPlaceSignatureHasher.sign, (DOMAIN, buffer, plan));
        bytes memory legacyCall = abi.encodeCall(LegacySignatureHasher.sign, (DOMAIN, preimage, ranges));

        uint256 before = gasleft();
        (bool okNew,) = address(inPlace).call(inPlaceCall);
        uint256 gasNew = before - gasleft();
        before = gasleft();
        (bool okOld,) = address(legacy).call(legacyCall);
        uint256 gasOld = before - gasleft();

        assertTrue(okNew, "in-place call reverted");
        assertTrue(okOld, "legacy call reverted");
        assertEq(inPlace.digest(), expected, "in-place digest");
        assertEq(legacy.digest(), expected, "legacy digest");

        if (bytes(label).length == 0) return;
        _report(label, buffer.length, plan.length, preimage.length, ranges.length);
        _report(label, inPlaceCall.length, gasNew, legacyCall.length, gasOld);
    }

    function _report(string memory label, uint256 a, uint256 b, uint256 c, uint256 d) private pure {
        console.log(label, a, b);
        console.log("  vs legacy", c, d);
    }

    /* STRUCTURE BUILDERS */

    function _word(bytes32 value) internal pure returns (HashPlanCompiler.Node memory) {
        return
            HashPlanCompiler.Node({kind: HashPlanCompiler.Kind.Word, word: value, data: "", children: new uint256[](0)});
    }

    function _bytes(bytes memory value) internal pure returns (HashPlanCompiler.Node memory) {
        return HashPlanCompiler.Node({
            kind: HashPlanCompiler.Kind.Bytes, word: bytes32(0), data: value, children: new uint256[](0)
        });
    }

    function _parent(HashPlanCompiler.Kind kind, bytes32 typeHash, uint256[] memory children)
        internal
        pure
        returns (HashPlanCompiler.Node memory)
    {
        return HashPlanCompiler.Node({kind: kind, word: typeHash, data: "", children: children});
    }

    function _indices(uint256 start, uint256 count) internal pure returns (uint256[] memory list) {
        list = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            list[i] = start + i;
        }
    }

    function _flat(uint256 fields) internal pure returns (HashPlanCompiler.Node[] memory nodes) {
        nodes = new HashPlanCompiler.Node[](fields + 1);
        for (uint256 i; i < fields; ++i) {
            nodes[i] = _word(bytes32(i + 1));
        }
        nodes[fields] = _parent(HashPlanCompiler.Kind.Struct, keccak256("Flat"), _indices(0, fields));
    }

    /// @dev Batch(Item[] items,uint256 nonce) with a single Item, the shape both READMEs use.
    function _batch() internal pure returns (HashPlanCompiler.Node[] memory nodes) {
        nodes = new HashPlanCompiler.Node[](7);
        nodes[0] = _word(bytes32(uint256(0x11))); // token
        nodes[1] = _word(bytes32(uint256(0x22))); // amount
        nodes[2] = _word(bytes32(uint256(0x33))); // recipient
        nodes[3] = _parent(HashPlanCompiler.Kind.Struct, keccak256("Item"), _indices(0, 3));
        uint256[] memory items = new uint256[](1);
        items[0] = 3;
        nodes[4] = _parent(HashPlanCompiler.Kind.Array, bytes32(0), items);
        nodes[5] = _word(bytes32(uint256(7))); // nonce
        uint256[] memory fields = new uint256[](2);
        (fields[0], fields[1]) = (4, 5);
        nodes[6] = _parent(HashPlanCompiler.Kind.Struct, keccak256("Batch"), fields);
    }

    function _message(bytes memory first, bytes memory second)
        internal
        pure
        returns (HashPlanCompiler.Node[] memory nodes)
    {
        nodes = new HashPlanCompiler.Node[](3);
        nodes[0] = _bytes(first);
        nodes[1] = _bytes(second);
        nodes[2] = _parent(HashPlanCompiler.Kind.Struct, keccak256("Message"), _indices(0, 2));
    }

    /// @dev A chain of single-field structs, the worst case for the superseded format's offset shifts.
    /// @dev Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)
    function _liquidLaneRequest() internal pure returns (HashPlanCompiler.Node[] memory nodes) {
        nodes = new HashPlanCompiler.Node[](11);
        nodes[0] = _word(bytes32(uint256(0xa1))); // output token
        nodes[1] = _word(bytes32(uint256(0xa2))); // output amount
        nodes[2] = _word(bytes32(uint256(0xa3))); // output recipient
        nodes[3] = _parent(HashPlanCompiler.Kind.Struct, keccak256("Output"), _indices(0, 3));
        uint256[] memory outputs = new uint256[](1);
        outputs[0] = 3;
        nodes[4] = _parent(HashPlanCompiler.Kind.Array, bytes32(0), outputs);
        nodes[5] = _word(bytes32(uint256(0xb1))); // tokenIn
        nodes[6] = _word(bytes32(uint256(0xb2))); // amountIn
        nodes[7] = _word(bytes32(uint256(0xb3))); // deadline
        nodes[8] = _word(bytes32(uint256(0xb4))); // nonce
        nodes[9] = _word(bytes32(uint256(0xb5))); // protocol
        uint256[] memory fields = new uint256[](6);
        (fields[0], fields[1], fields[2]) = (5, 6, 4);
        (fields[3], fields[4], fields[5]) = (7, 8, 9);
        nodes[10] = _parent(HashPlanCompiler.Kind.Struct, keccak256("Request"), fields);
    }

    function _chain(uint256 depth) internal pure returns (HashPlanCompiler.Node[] memory nodes) {
        nodes = new HashPlanCompiler.Node[](depth + 1);
        nodes[0] = _word(bytes32(uint256(0xdead)));
        for (uint256 i = 1; i <= depth; ++i) {
            uint256[] memory child = new uint256[](1);
            child[0] = i - 1;
            nodes[i] = _parent(HashPlanCompiler.Kind.Struct, keccak256(abi.encode("Level", i)), child);
        }
    }
}
