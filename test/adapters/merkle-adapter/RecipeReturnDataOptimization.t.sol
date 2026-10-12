// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Recipes} from "src/contracts/merkle-adapter/Recipes.sol";

import {
    IRecipes,
    OP_ADD,
    OP_CALL,
    OP_CALL_IF,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MAX,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
    OP_READ_CACHED,
    OP_READ_IF,
    OP_READ_WORD,
    OP_SATURATING_SUB,
    OP_SUB,
    SRC_INPUT,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Test} from "forge-std/Test.sol";

import {LibBytes} from "solady/utils/LibBytes.sol";

contract RecipeReturnDataOptimizationTest is Test {
    address internal _harness;
    address internal _target;

    function setUp() public {
        _harness = address(new RecipeReturnDataHarness());
        _target = address(new RecipeReturnDataTarget());
    }

    function test_ResponseLengthsOffsetsAndActiveReadIf() public {
        uint256[9] memory lengths = [uint256(0), 1, 31, 32, 33, 63, 64, 128, 8192];
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory raw = _buffer(lengths[i]);
            RecipeReturnDataTarget(_target).configure(raw, false);
            uint256[6] memory offsets = [
                uint256(0),
                1,
                lengths[i] >= 32 ? lengths[i] - 32 : 0,
                lengths[i] >= 31 ? lengths[i] - 31 : 0,
                type(uint256).max - 31,
                type(uint256).max
            ];
            for (uint256 j; j < offsets.length; ++j) {
                for (uint256 conditional; conditional < 2; ++conditional) {
                    (bool success, bytes memory response) = _compareRead(
                        _target, abi.encodeCall(RecipeReturnDataTarget.read, ()), offsets[j], conditional > 0
                    );
                    if (offsets[j] > type(uint256).max - 32) {
                        assertFalse(success);
                        assertEq(response, abi.encodeWithSignature("Panic(uint256)", 0x11));
                    } else if (offsets[j] + 32 > raw.length) {
                        assertFalse(success);
                        assertEq(response, abi.encodeWithSelector(IRecipes.InvalidQuery.selector));
                    } else {
                        assertTrue(success);
                        assertEq(abi.decode(response, (uint256[]))[0], _word(raw, offsets[j]));
                    }
                }
            }
        }
    }

    function testFuzz_ValidReadAndCachedOffsetsKeepEveryBit(uint256 a, uint256 b, uint8 newOffset) public {
        uint256 offset = bound(newOffset, 0, 32);
        bytes memory raw = abi.encode(a, b);
        RecipeReturnDataTarget(_target).configure(raw, false);
        for (uint256 conditional; conditional < 2; ++conditional) {
            (bool success, bytes memory response) =
                _compareRead(_target, abi.encodeCall(RecipeReturnDataTarget.read, ()), offset, conditional > 0);
            assertTrue(success);
            assertEq(abi.decode(response, (uint256[]))[0], _word(raw, offset));
        }
        bytes[] memory queries = _queries(_target, abi.encodeCall(RecipeReturnDataTarget.read, ()), 0);
        bytes[] memory steps = new bytes[](3);
        steps[0] = _read(OP_READ_CACHED, 0);
        steps[1] = _read(OP_READ, 0);
        steps[2] = _cached(0, offset);
        (bool success, bytes memory response) = _compare(queries, steps, new uint256[](0));
        assertTrue(success);
        assertEq(abi.decode(response, (uint256[]))[2], _word(raw, offset));
    }

    function test_NoCodeAndPrecompileResponsesKeepAddressValidation() public {
        address noCode = address(0xbabe);
        for (uint256 conditional; conditional < 2; ++conditional) {
            (bool success, bytes memory response) = _compareRead(noCode, hex"", type(uint256).max, conditional > 0);
            assertFalse(success);
            assertEq(response, abi.encodeWithSelector(Address.AddressEmptyCode.selector, noCode));
            (success, response) = _compareCall(noCode, hex"", conditional > 0);
            assertFalse(success);
            assertEq(response, abi.encodeWithSelector(Address.AddressEmptyCode.selector, noCode));
            (success, response) = _compareRead(address(4), abi.encode(type(uint256).max), 0, conditional > 0);
            assertTrue(success);
            assertEq(abi.decode(response, (uint256[]))[0], type(uint256).max);
            (success,) = _compareCall(address(4), abi.encode(type(uint256).max), conditional > 0);
            assertTrue(success);
            (success, response) = _compareRead(address(4), hex"", 0, conditional > 0);
            assertFalse(success);
            assertEq(response, abi.encodeWithSelector(Address.AddressEmptyCode.selector, address(4)));
            (success, response) = _compareCall(address(4), hex"", conditional > 0);
            assertFalse(success);
            assertEq(response, abi.encodeWithSelector(Address.AddressEmptyCode.selector, address(4)));
        }
    }

    function test_RawRevertsRemainExactBeforeOffsetOverflow() public {
        bytes[6] memory failures = [
            bytes(""),
            abi.encodeWithSignature("Custom(uint256)", type(uint256).max),
            abi.encodeWithSignature("Panic(uint256)", 0x11),
            abi.encodeWithSignature("Error(string)", "target failure"),
            bytes(hex"123456789abcdef001"),
            _buffer(8192)
        ];
        for (uint256 i; i < failures.length; ++i) {
            RecipeReturnDataTarget(_target).configure(failures[i], true);
            bytes memory expected =
                failures[i].length > 0 ? failures[i] : abi.encodeWithSelector(Errors.FailedCall.selector);
            for (uint256 conditional; conditional < 2; ++conditional) {
                (bool success, bytes memory response) = _compareRead(
                    _target, abi.encodeCall(RecipeReturnDataTarget.read, ()), type(uint256).max, conditional > 0
                );
                assertFalse(success);
                assertEq(response, expected);
                (success, response) =
                    _compareCall(_target, abi.encodeCall(RecipeReturnDataTarget.write, (uint256(19))), conditional > 0);
                assertFalse(success);
                assertEq(response, expected);
                assertEq(RecipeReturnDataTarget(_target).calls(), 0);
            }
        }
    }

    function test_CallResponseLengthsEffectsAndRollback() public {
        uint256[6] memory lengths = [uint256(0), 1, 31, 32, 128, 8192];
        for (uint256 i; i < lengths.length; ++i) {
            RecipeReturnDataTarget(_target).configure(_buffer(lengths[i]), false);
            for (uint256 conditional; conditional < 2; ++conditional) {
                uint256 priorCalls = RecipeReturnDataTarget(_target).calls();
                (bool success, bytes memory response) =
                    _compareCall(_target, abi.encodeCall(RecipeReturnDataTarget.write, (uint256(19))), conditional > 0);
                assertTrue(success);
                assertEq(abi.decode(response, (uint256[]))[0], 0);
                assertEq(RecipeReturnDataTarget(_target).value(), 19);
                assertEq(RecipeReturnDataTarget(_target).calls(), priorCalls + 1);
                assertEq(RecipeReturnDataTarget(_target).sender(), _harness);
                assertEq(RecipeReturnDataTarget(_target).receivedValue(), 0);
                bytes[] memory steps = new bytes[](2);
                steps[0] = _call(_target, abi.encodeCall(RecipeReturnDataTarget.write, (uint256(23))), conditional > 0);
                steps[1] = abi.encodePacked(OP_EQUAL, abi.encode(uint256(0), uint256(1)));
                (success, response) = _compare(new bytes[](0), steps, new uint256[](0));
                assertFalse(success);
                assertEq(response, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
                assertEq(RecipeReturnDataTarget(_target).value(), 19);
                assertEq(RecipeReturnDataTarget(_target).calls(), priorCalls + 1);
            }
        }
    }

    function test_StaticMutationStillFails() public {
        for (uint256 conditional; conditional < 2; ++conditional) {
            (bool success, bytes memory response) =
                _compareRead(_target, abi.encodeCall(RecipeReturnDataTarget.mutatingRead, ()), 0, conditional > 0);
            assertFalse(success);
            assertEq(response, abi.encodeWithSelector(Errors.FailedCall.selector));
            assertEq(RecipeReturnDataTarget(_target).value(), 7);
        }
    }

    function test_SkippedReadAndCallIgnoreUnusedMetadata() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = hex"ff";
        bytes[] memory steps = new bytes[](2);
        steps[0] = abi.encodePacked(OP_READ_IF, abi.encode(uint256(0), type(uint256).max, _input(0)));
        steps[1] = abi.encodePacked(OP_CALL_IF, abi.encode(uint256(0)));
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = type(uint256).max;
        (bool success, bytes memory response) = _compare(queries, steps, inputs);
        assertTrue(success);
        uint256[] memory values = abi.decode(response, (uint256[]));
        assertEq(values[0], type(uint256).max);
        assertEq(values[1], 0);
        assertEq(RecipeReturnDataTarget(_target).calls(), 0);
    }

    function test_CacheProducerReplacementAndReferenceErrors() public {
        RecipeReturnDataTarget(_target).configure(abi.encode(type(uint256).max, uint256(11)), false);
        bytes[] memory queries = _queries(_target, abi.encodeCall(RecipeReturnDataTarget.read, ()), 0);
        bytes[] memory steps = new bytes[](4);
        steps[0] = _read(OP_READ_CACHED, 0);
        steps[1] = _read(OP_READ, 0);
        steps[2] = _cached(0, 32);
        steps[3] = _cached(0, 1);
        (bool success, bytes memory response) = _compare(queries, steps, new uint256[](0));
        assertTrue(success);
        assertEq(abi.decode(response, (uint256[]))[2], 11);
        assertEq(abi.decode(response, (uint256[]))[3], _word(abi.encode(type(uint256).max, uint256(11)), 1));
        steps = new bytes[](3);
        steps[0] = _read(OP_READ_CACHED, 0);
        bytes[] memory replacements = new bytes[](2);
        replacements[0] = queries[0];
        replacements[1] =
            abi.encode(_target, abi.encodeCall(RecipeReturnDataTarget.tuple, ()), new uint256[](0), uint256(0));
        queries = replacements;
        steps[1] = _read(OP_READ_CACHED, 1);
        steps[2] = _cached(1, 0);
        (success, response) = _compare(queries, steps, new uint256[](0));
        assertTrue(success);
        assertEq(abi.decode(response, (uint256[]))[2], 7);
        steps[2] = _cached(0, 0);
        _expect(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        steps[2] = _cached(2, 0);
        _expect(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        steps[0] = _read(OP_READ, 0);
        steps[1] = _cached(0, 0);
        _expect(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        steps = new bytes[](1);
        steps[0] = _cached(0, 0);
        _expect(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        steps = new bytes[](2);
        steps[0] = _read(OP_READ_CACHED, 0);
        steps[1] = _cached(0, 33);
        _expect(queries, steps, abi.encodeWithSelector(IRecipes.InvalidQuery.selector));
        steps[1] = _cached(0, type(uint256).max);
        _expect(queries, steps, abi.encodeWithSignature("Panic(uint256)", 0x11));
    }

    function test_MalformedMetadataAndBindingsRemainChecked() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = hex"ff";
        bytes[] memory steps = new bytes[](1);
        steps[0] = _read(OP_READ, 0);
        (bool success,) = _compare(queries, steps, new uint256[](0));
        assertFalse(success);
        steps[0] = abi.encodePacked(OP_CALL, hex"ff");
        (success,) = _compare(queries, steps, new uint256[](0));
        assertFalse(success);
        uint256[] memory bindings = new uint256[](2);
        bindings[0] = (uint256(4) << 224) | _input(0);
        bindings[1] = (uint256(4) << 224) | _input(0);
        bytes memory data = abi.encodeCall(RecipeReturnDataTarget.echo, (uint256(0)));
        queries[0] = abi.encode(_target, data, bindings, uint256(0));
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = type(uint256).max;
        steps[0] = _read(OP_READ, 0);
        bytes memory response;
        (success, response) = _compare(queries, steps, inputs);
        assertFalse(success);
        assertEq(response, abi.encodeWithSelector(IRecipes.InvalidCall.selector));
        bindings = new uint256[](1);
        bindings[0] = (uint256(4) << 224) | _input(0);
        queries[0] = abi.encode(_target, data, bindings, uint256(0));
        (success, response) = _compare(queries, steps, inputs);
        assertTrue(success);
        assertEq(abi.decode(response, (uint256[]))[0], type(uint256).max);
        bindings[0] = (uint256(type(uint32).max) << 224) | _input(99);
        queries[0] = abi.encode(_target, data, bindings, uint256(0));
        (success, response) = _compare(queries, steps, inputs);
        assertFalse(success);
        assertEq(response, abi.encodeWithSelector(IRecipes.InvalidCall.selector));
    }

    /// forge-config: default.isolate = true
    function test_GasO07Scalar32() public {
        _gasRead(abi.encodeWithSignature("value()"), OP_READ, "scalar32", 7);
    }

    /// forge-config: default.isolate = true
    function test_GasO07Tuple128() public {
        _gasRead(abi.encodeCall(RecipeReturnDataTarget.tuple, ()), OP_READ, "tuple128", 7);
    }

    /// forge-config: default.isolate = true
    function test_GasO07IgnoredCallEmpty() public {
        _gasCall(abi.encodeCall(RecipeReturnDataTarget.voidSet, (uint256(19))), "ignoredCallEmpty");
    }

    /// forge-config: default.isolate = true
    function test_GasO07IgnoredCall32() public {
        _gasCall(abi.encodeCall(RecipeReturnDataTarget.wordSet, (uint256(19))), "ignoredCall32");
    }

    /// forge-config: default.isolate = true
    function test_GasO07ReadIfSkipped() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_READ_IF, abi.encode(uint256(0), type(uint256).max, uint256(7)));
        uint256[] memory values = RecipeReturnDataHarness(_harness).proposed(new bytes[](0), steps, new uint256[](0));
        vm.snapshotGasLastCall("RecipeReturnData", "readIfSkipped");
        assertEq(values[0], 7);
    }

    /// forge-config: default.isolate = true
    function test_GasO07CallIfSkipped() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_CALL_IF, abi.encode(uint256(0)));
        uint256[] memory values = RecipeReturnDataHarness(_harness).proposed(new bytes[](0), steps, new uint256[](0));
        vm.snapshotGasLastCall("RecipeReturnData", "callIfSkipped");
        assertEq(values[0], 0);
        assertEq(RecipeReturnDataTarget(_target).calls(), 0);
    }

    /// forge-config: default.isolate = true
    function test_GasO07Cached128() public {
        bytes[] memory queries = _queries(_target, abi.encodeCall(RecipeReturnDataTarget.tuple, ()), 0);
        bytes[] memory steps = new bytes[](2);
        steps[0] = _read(OP_READ_CACHED, 0);
        steps[1] = _cached(0, 32);
        uint256[] memory values = RecipeReturnDataHarness(_harness).proposed(queries, steps, new uint256[](0));
        vm.snapshotGasLastCall("RecipeReturnData", "cached128");
        assertEq(values[0], 7);
        assertEq(values[1], 11);
    }

    function _gasRead(bytes memory data, uint8 operation, string memory label, uint256 expected) internal {
        bytes[] memory queries = _queries(_target, data, 0);
        bytes[] memory steps = new bytes[](1);
        steps[0] = _read(operation, 0);
        uint256[] memory values = RecipeReturnDataHarness(_harness).proposed(queries, steps, new uint256[](0));
        vm.snapshotGasLastCall("RecipeReturnData", label);
        assertEq(values[0], expected);
    }

    function _gasCall(bytes memory data, string memory label) internal {
        bytes[] memory steps = new bytes[](1);
        steps[0] = _call(_target, data, false);
        uint256[] memory values = RecipeReturnDataHarness(_harness).proposed(new bytes[](0), steps, new uint256[](0));
        vm.snapshotGasLastCall("RecipeReturnData", label);
        assertEq(values[0], 0);
        assertEq(RecipeReturnDataTarget(_target).value(), 19);
        assertEq(RecipeReturnDataTarget(_target).calls(), 1);
        assertEq(RecipeReturnDataTarget(_target).sender(), _harness);
        assertEq(RecipeReturnDataTarget(_target).receivedValue(), 0);
    }

    function _compareRead(address target, bytes memory data, uint256 offset, bool conditional)
        internal
        returns (bool, bytes memory)
    {
        bytes[] memory steps = new bytes[](1);
        steps[0] = _read(conditional ? OP_READ_IF : OP_READ, 0);
        return _compare(_queries(target, data, offset), steps, new uint256[](0));
    }

    function _compareCall(address target, bytes memory data, bool conditional) internal returns (bool, bytes memory) {
        bytes[] memory steps = new bytes[](1);
        steps[0] = _call(target, data, conditional);
        return _compare(new bytes[](0), steps, new uint256[](0));
    }

    function _compare(bytes[] memory queries, bytes[] memory steps, uint256[] memory inputs)
        internal
        returns (bool success, bytes memory response)
    {
        uint256 snapshot = vm.snapshotState();
        // Fixed ample gas keeps the deliberately invalid STATICCALL from exhausting the test frame.
        (bool legacySuccess, bytes memory legacyResponse) =
            _harness.call{gas: 2_000_000}(abi.encodeCall(RecipeReturnDataHarness.legacy, (queries, steps, inputs)));
        bytes memory effects = _effects();
        assertTrue(vm.revertToState(snapshot));
        (success, response) =
            _harness.call{gas: 2_000_000}(abi.encodeCall(RecipeReturnDataHarness.proposed, (queries, steps, inputs)));
        assertEq(success, legacySuccess);
        assertEq(response, legacyResponse);
        assertEq(_effects(), effects);
    }

    function _effects() internal view returns (bytes memory) {
        return abi.encode(
            RecipeReturnDataTarget(_target).value(),
            RecipeReturnDataTarget(_target).calls(),
            RecipeReturnDataTarget(_target).sender(),
            RecipeReturnDataTarget(_target).receivedValue()
        );
    }

    function _expect(bytes[] memory queries, bytes[] memory steps, bytes memory expected) internal {
        (bool success, bytes memory response) = _compare(queries, steps, new uint256[](0));
        assertFalse(success);
        assertEq(response, expected);
    }

    function _queries(address target, bytes memory data, uint256 offset)
        internal
        pure
        returns (bytes[] memory queries)
    {
        queries = new bytes[](1);
        queries[0] = abi.encode(target, data, new uint256[](0), offset);
    }

    function _read(uint8 operation, uint256 index) internal pure returns (bytes memory) {
        return operation == OP_READ_IF
            ? abi.encodePacked(operation, abi.encode(uint256(1), index, _result(999)))
            : abi.encodePacked(operation, abi.encode(index));
    }

    function _call(address target, bytes memory data, bool conditional) internal pure returns (bytes memory) {
        return conditional
            ? abi.encodePacked(OP_CALL_IF, abi.encode(uint256(1), target, data, new uint256[](0)))
            : abi.encodePacked(OP_CALL, abi.encode(target, data, new uint256[](0)));
    }

    function _cached(uint256 producer, uint256 offset) internal pure returns (bytes memory) {
        return abi.encodePacked(OP_READ_WORD, abi.encode(producer, offset));
    }

    function _input(uint256 index) internal pure returns (uint256) {
        return (uint256(SRC_INPUT) << 216) | index;
    }

    function _result(uint256 index) internal pure returns (uint256) {
        return (uint256(SRC_RESULT) << 216) | index;
    }

    function _word(bytes memory data, uint256 offset) internal pure returns (uint256 value) {
        assembly ("memory-safe") { value := mload(add(add(data, 32), offset)) }
    }

    function _buffer(uint256 length) internal pure returns (bytes memory data) {
        data = new bytes(length);
        for (uint256 i; i < length; ++i) {
            data[i] = bytes1(uint8(i));
        }
    }
}

/// @dev Same-address legacy/live oracle; the baseline interpreter body is frozen before production edits.
contract RecipeReturnDataHarness is Recipes {
    using Address for address;
    using LibBytes for bytes;
    using Math for uint256;

    function legacy(bytes[] calldata queries, bytes[] calldata steps, uint256[] calldata inputs)
        public
        returns (uint256[] memory)
    {
        return _execute(queries, steps, inputs, true);
    }

    function proposed(bytes[] calldata queries, bytes[] calldata steps, uint256[] calldata inputs)
        public
        returns (uint256[] memory)
    {
        return _execute(queries, steps, inputs, false);
    }

    function _execute(bytes[] calldata queries, bytes[] calldata steps, uint256[] calldata inputs, bool baseline)
        internal
        returns (uint256[] memory)
    {
        State memory state;
        state.values = new uint256[](steps.length);
        for (; state.index < steps.length; ++state.index) {
            if (baseline) {
                state.values[state.index] = _legacyRun(queries, steps, inputs, state);
            } else {
                state.values[state.index] = _run(queries, steps, inputs, state);
            }
        }
        return state.values;
    }

    function _legacyRun(bytes[] calldata queries, bytes[] calldata steps, uint256[] calldata inputs, State memory state)
        internal
        returns (uint256)
    {
        (uint8 operation, bytes calldata operationData) = _step(steps[state.index]);
        if (operation == OP_READ || (operation == OP_READ_IF || operation == OP_READ_CACHED)) {
            uint256 queryIndex;
            if (operation == OP_READ_IF) {
                uint256 gate;
                uint256 fallbackValue;
                (gate, queryIndex, fallbackValue) = abi.decode(operationData, (uint256, uint256, uint256));
                if (_value(gate, steps, inputs, state) == 0) return _value(fallbackValue, steps, inputs, state);
            } else {
                queryIndex = abi.decode(operationData, (uint256));
            }
            (address target, bytes memory data, uint256[] memory bindings, uint256 offset) =
                abi.decode(queries[queryIndex], (address, bytes, uint256[], uint256));
            _bind(data, bindings, steps, inputs, state);
            bytes memory result = target.functionStaticCall(data);
            if (offset + 32 > result.length) revert InvalidQuery();
            if (operation == OP_READ_CACHED) {
                state.readData = result;
                state.readIndex = state.index + 1;
            }
            return uint256(result.load(offset));
        } else if (operation == OP_CALL || operation == OP_CALL_IF) {
            address target;
            bytes memory data;
            uint256[] memory bindings;
            if (operation == OP_CALL_IF) {
                if (_value(abi.decode(operationData, (uint256)), steps, inputs, state) == 0) return 0;
                (, target, data, bindings) = abi.decode(operationData, (uint256, address, bytes, uint256[]));
            } else {
                (target, data, bindings) = abi.decode(operationData, (address, bytes, uint256[]));
            }
            _bind(data, bindings, steps, inputs, state);
            target.functionCall(data);
        } else if (operation <= OP_LESS_OR_EQUAL) {
            (uint256 a, uint256 b) = abi.decode(operationData, (uint256, uint256));
            a = _value(a, steps, inputs, state);
            b = _value(b, steps, inputs, state);
            if (operation == OP_ADD) return a + b;
            if (operation == OP_SUB) return a - b;
            if (operation == OP_SATURATING_SUB) return a.saturatingSub(b);
            if (operation == OP_MIN) return Math.min(a, b);
            if (operation == OP_MAX) return Math.max(a, b);
            if (operation == OP_MUL_DIV) {
                // The first two packed operands occupy 64 bytes.
                return a * b / _value(abi.decode(operationData[64:], (uint256)), steps, inputs, state);
            }
            if (operation == OP_EQUAL ? a != b : a > b) revert CheckFailed();
        } else if (operation == OP_READ_WORD) {
            (uint256 producerIndex, uint256 offset) = abi.decode(operationData, (uint256, uint256));
            if (
                producerIndex >= state.index || state.readIndex != producerIndex + 1
                    || uint8(steps[producerIndex][0]) != OP_READ_CACHED
            ) revert InvalidReference();
            if (offset + 32 > state.readData.length) revert InvalidQuery();
            return uint256(state.readData.load(offset));
        } else {
            revert InvalidOperation();
        }
        return 0;
    }
}

contract RecipeReturnDataTarget {
    uint256 public value = 7;
    uint256 public calls;
    address public sender;
    uint256 public receivedValue;
    bytes internal _response;
    bool internal _fails;

    function configure(bytes memory newResponse, bool newFails) public {
        _response = newResponse;
        _fails = newFails;
    }

    function read() public view {
        bytes memory response = _response;
        if (_fails) {
            assembly ("memory-safe") { revert(add(response, 32), mload(response)) }
        }
        assembly ("memory-safe") { return(add(response, 32), mload(response)) }
    }

    function write(uint256 newValue) public payable {
        value = newValue;
        calls++;
        sender = msg.sender;
        receivedValue = msg.value;
        bytes memory response = _response;
        if (_fails) {
            assembly ("memory-safe") { revert(add(response, 32), mload(response)) }
        }
        assembly ("memory-safe") { return(add(response, 32), mload(response)) }
    }

    function mutatingRead() public returns (uint256) {
        value++;
        return value;
    }

    function echo(uint256 input) public pure returns (uint256) {
        return input;
    }

    function tuple() public view returns (uint256, uint256, uint256, address) {
        return (value, 11, calls, msg.sender);
    }

    function voidSet(uint256 newValue) public payable {
        value = newValue;
        calls++;
        sender = msg.sender;
        receivedValue = msg.value;
    }

    function wordSet(uint256 newValue) public payable returns (uint256) {
        voidSet(newValue);
        return newValue;
    }
}
