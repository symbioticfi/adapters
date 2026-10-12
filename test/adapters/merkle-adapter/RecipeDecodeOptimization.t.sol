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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {Test} from "forge-std/Test.sol";

contract RecipeDecodeOptimizationTest is Test {
    address internal _harness;
    address internal _target;

    function setUp() public {
        _harness = address(new RecipeDecodeHarness());
        _target = address(new RecipeDecodeTarget());
    }

    function testFuzz_AllArithmeticPreservesFullWidthErrors(uint256 a, uint256 b, uint256 divisor) public {
        uint256[] memory inputs = new uint256[](3);
        inputs[0] = a;
        inputs[1] = b;
        inputs[2] = divisor;
        bytes[] memory steps = new bytes[](1);
        for (uint8 operation = OP_ADD; operation <= OP_LESS_OR_EQUAL; ++operation) {
            steps[0] = operation == OP_MUL_DIV
                ? abi.encodePacked(operation, abi.encode(_input(0), _input(1), _input(2)))
                : abi.encodePacked(operation, abi.encode(_input(0), _input(1)));
            _compare(new bytes[](0), steps, inputs);
        }
    }

    function testFuzz_ValidArithmeticRetainsAllResults(uint128 a, uint128 b, uint128 divisor) public {
        uint256[] memory inputs = new uint256[](3);
        inputs[0] = a;
        inputs[1] = b;
        inputs[2] = bound(divisor, 1, type(uint128).max);
        bytes[] memory steps = new bytes[](6);
        steps[0] = _binary(OP_ADD, _input(0), _input(1));
        steps[1] = _binary(OP_SUB, _result(0), _input(1));
        steps[2] = _binary(OP_MIN, _input(0), _input(1));
        steps[3] = _binary(OP_MAX, _input(0), _input(1));
        steps[4] = _binary(OP_SATURATING_SUB, _input(0), _input(1));
        steps[5] = abi.encodePacked(OP_MUL_DIV, abi.encode(_input(0), _input(1), _input(2)));
        (bool success, bytes memory response) = _compare(new bytes[](0), steps, inputs);
        assertTrue(success);
        uint256[] memory values = abi.decode(response, (uint256[]));
        assertEq(values[0], uint256(a) + b);
        assertEq(values[1], a);
        assertEq(values[2], a < b ? a : b);
        assertEq(values[3], a > b ? a : b);
        assertEq(values[4], a > b ? a - b : 0);
        assertEq(values[5], uint256(a) * b / inputs[2]);
    }

    function test_CheckedPanicsAndChecksRemainExact() public {
        bytes[] memory steps = new bytes[](1);
        uint256[] memory inputs = new uint256[](3);
        inputs[0] = type(uint256).max;
        inputs[1] = 2;
        inputs[2] = type(uint256).max;
        steps[0] = _binary(OP_ADD, _input(0), _input(1));
        _expect(steps, inputs, abi.encodeWithSignature("Panic(uint256)", 0x11));
        steps[0] = _binary(OP_SUB, 0, 1);
        _expect(steps, inputs, abi.encodeWithSignature("Panic(uint256)", 0x11));
        steps[0] = abi.encodePacked(OP_MUL_DIV, abi.encode(_input(0), _input(1), _input(2)));
        _expect(steps, inputs, abi.encodeWithSignature("Panic(uint256)", 0x11));
        steps[0] = abi.encodePacked(OP_MUL_DIV, abi.encode(uint256(1), uint256(1), uint256(0)));
        _expect(steps, inputs, abi.encodeWithSignature("Panic(uint256)", 0x12));
        steps[0] = _binary(OP_EQUAL, 1, 2);
        _expect(steps, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
        steps[0] = _binary(OP_LESS_OR_EQUAL, 2, 1);
        _expect(steps, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
    }

    function test_MulDivFaultPrecedenceMatchesReference() public {
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = type(uint256).max;
        inputs[1] = 2;
        uint256[4] memory denominators = [_input(99), _result(0), uint256(3) << 216, uint256(0)];
        bytes[] memory steps = new bytes[](1);
        for (uint256 i; i < denominators.length; ++i) {
            steps[0] = abi.encodePacked(OP_MUL_DIV, abi.encode(_input(0), _input(1), denominators[i]));
            (bool success,) = _compare(new bytes[](0), steps, inputs);
            assertFalse(success);
        }
    }

    function test_OutOfBoundsBindingsRejectBeforeResolvingTheirSource() public {
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = (uint256(type(uint32).max) << 224) | _input(99);
        bytes[] memory steps = new bytes[](1);
        steps[0] = _call(OP_CALL, abi.encodeCall(RecipeDecodeTarget.set, (uint256(0))), bindings, 1);
        _expect(steps, new uint256[](0), abi.encodeWithSelector(IRecipes.InvalidCall.selector));
        steps[0] = _call(OP_CALL, hex"1234", bindings, 1);
        _expect(steps, new uint256[](0), abi.encodeWithSelector(IRecipes.InvalidCall.selector));
    }

    function testFuzz_ReadsBindingsAndCacheKeepFullWidth(uint256 a, uint256 b) public {
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = a;
        inputs[1] = b;
        uint256[] memory bindings = new uint256[](2);
        bindings[0] = (uint256(4) << 224) | _input(0);
        bindings[1] = (uint256(36) << 224) | _input(1);
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(RecipeDecodeTarget.tuple, (uint256(0), uint256(0))), bindings, 32);
        bytes[] memory steps = new bytes[](7);
        steps[0] = abi.encodePacked(OP_READ_CACHED, abi.encode(uint256(0)));
        steps[1] = abi.encodePacked(OP_READ_WORD, abi.encode(uint256(0), uint256(0)));
        steps[2] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        steps[3] = abi.encodePacked(OP_READ_IF, abi.encode(uint256(1), uint256(0), _result(999)));
        steps[4] = abi.encodePacked(OP_READ_IF, abi.encode(uint256(0), type(uint256).max, _input(0)));
        bindings = new uint256[](1);
        bindings[0] = (uint256(4) << 224) | _result(1);
        steps[5] = _call(OP_CALL, abi.encodeCall(RecipeDecodeTarget.set, (uint256(0))), bindings, 1);
        steps[6] = abi.encodePacked(OP_READ_WORD, abi.encode(uint256(0), uint256(32)));
        (bool success, bytes memory response) = _compare(queries, steps, inputs);
        assertTrue(success);
        uint256[] memory values = abi.decode(response, (uint256[]));
        assertEq(values[0], b);
        assertEq(values[1], a);
        assertEq(values[2], b);
        assertEq(values[3], b);
        assertEq(values[4], a);
        assertEq(values[6], b);
        assertEq(RecipeDecodeTarget(_target).value(), a);
        assertEq(RecipeDecodeTarget(_target).sender(), _harness);
        assertEq(RecipeDecodeTarget(_target).receivedValue(), 0);
    }

    function testFuzz_UnalignedCachedWords(uint256 a, uint256 b, uint8 offset) public {
        offset = uint8(bound(offset, 0, 32));
        bytes memory raw = abi.encode(a, b);
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(RecipeDecodeTarget.raw, (raw)), new uint256[](0), 0);
        bytes[] memory steps = new bytes[](2);
        steps[0] = abi.encodePacked(OP_READ_CACHED, abi.encode(uint256(0)));
        steps[1] = abi.encodePacked(OP_READ_WORD, abi.encode(uint256(0), uint256(offset)));
        (bool success, bytes memory response) = _compare(queries, steps, new uint256[](0));
        assertTrue(success);
        uint256 expected;
        assembly ("memory-safe") { expected := mload(add(add(raw, 32), offset)) }
        assertEq(abi.decode(response, (uint256[]))[1], expected);
    }

    function test_CachedProducerIdentityAndOffsetsRemainChecked() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(RecipeDecodeTarget.tuple, (uint256(7), uint256(11))), new uint256[](0), 0);
        bytes[] memory steps = new bytes[](3);
        steps[0] = abi.encodePacked(OP_READ_CACHED, abi.encode(uint256(0)));
        steps[1] = abi.encodePacked(OP_READ_CACHED, abi.encode(uint256(0)));
        steps[2] = abi.encodePacked(OP_READ_WORD, abi.encode(uint256(0), uint256(32)));
        (bool success, bytes memory response) = _compare(queries, steps, new uint256[](0));
        assertFalse(success);
        assertEq(response, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        steps[2] = abi.encodePacked(OP_READ_WORD, abi.encode(uint256(1), uint256(32)));
        (success, response) = _compare(queries, steps, new uint256[](0));
        assertTrue(success);
        assertEq(abi.decode(response, (uint256[]))[2], 11);
        steps[1] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        steps[2] = abi.encodePacked(OP_READ_WORD, abi.encode(uint256(0), uint256(33)));
        (success, response) = _compare(queries, steps, new uint256[](0));
        assertFalse(success);
        assertEq(response, abi.encodeWithSelector(IRecipes.InvalidQuery.selector));
        steps[2] = abi.encodePacked(OP_READ_WORD, abi.encode(uint256(0), type(uint256).max));
        (success, response) = _compare(queries, steps, new uint256[](0));
        assertFalse(success);
        assertEq(response, abi.encodeWithSignature("Panic(uint256)", 0x11));
    }

    function test_SkippedOperationsIgnoreUnusedMetadata() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = hex"deadbeef";
        bytes[] memory steps = new bytes[](2);
        steps[0] = abi.encodePacked(OP_READ_IF, abi.encode(uint256(0), type(uint256).max, _input(0)));
        steps[1] = abi.encodePacked(OP_CALL_IF, abi.encode(uint256(0)));
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = type(uint256).max;
        (bool success, bytes memory response) = _compare(queries, steps, inputs);
        assertTrue(success);
        assertEq(abi.decode(response, (uint256[]))[0], type(uint256).max);
        assertEq(RecipeDecodeTarget(_target).calls(), 0);
    }

    function test_ActiveConditionalCallAndRollbackRemainAtomic() public {
        bytes[] memory steps = new bytes[](2);
        steps[0] = _call(OP_CALL_IF, abi.encodeCall(RecipeDecodeTarget.set, (uint256(13))), new uint256[](0), 1);
        steps[1] = _binary(OP_EQUAL, 1, 2);
        _expect(steps, new uint256[](0), abi.encodeWithSelector(IRecipes.CheckFailed.selector));
        assertEq(RecipeDecodeTarget(_target).calls(), 0);
        assertEq(RecipeDecodeTarget(_target).value(), 0);
        steps = new bytes[](1);
        steps[0] = _call(OP_CALL_IF, abi.encodeCall(RecipeDecodeTarget.set, (uint256(13))), new uint256[](0), 1);
        (bool success,) = _compare(new bytes[](0), steps, new uint256[](0));
        assertTrue(success);
        assertEq(RecipeDecodeTarget(_target).value(), 13);
        assertEq(RecipeDecodeTarget(_target).calls(), 1);
        assertEq(RecipeDecodeTarget(_target).sender(), _harness);
    }

    function test_BindingErrorsPrecedeOperandAndTargetErrors() public {
        bytes[] memory steps = new bytes[](1);
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = (uint256(3) << 224) | _input(99);
        steps[0] = _call(OP_CALL, abi.encodeCall(RecipeDecodeTarget.set, (uint256(0))), bindings, 1);
        _expect(steps, new uint256[](0), abi.encodeWithSelector(IRecipes.InvalidCall.selector));
        bindings[0] = (uint256(4) << 224) | _input(99);
        steps[0] = _call(OP_CALL, abi.encodeCall(RecipeDecodeTarget.set, (uint256(0))), bindings, 1);
        _expect(steps, new uint256[](0), abi.encodeWithSignature("Panic(uint256)", 0x32));
        bindings = new uint256[](2);
        bindings[0] = uint256(4) << 224;
        bindings[1] = uint256(4) << 224;
        steps[0] = _call(OP_CALL, abi.encodeCall(RecipeDecodeTarget.set, (uint256(0))), bindings, 1);
        _expect(steps, new uint256[](0), abi.encodeWithSelector(IRecipes.InvalidCall.selector));
        assertEq(RecipeDecodeTarget(_target).calls(), 0);
    }

    function test_InvalidSourcesAndForwardOrNonnumericalReferences() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = _binary(OP_ADD, uint256(3) << 216, 0);
        _expect(steps, new uint256[](0), abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        steps[0] = _binary(OP_ADD, _result(0), 0);
        _expect(steps, new uint256[](0), abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        steps[0] = _binary(OP_ADD, _input(0), 0);
        _expect(steps, new uint256[](0), abi.encodeWithSignature("Panic(uint256)", 0x32));
        steps = new bytes[](2);
        steps[0] = _binary(OP_EQUAL, 1, 1);
        steps[1] = _binary(OP_ADD, _result(0), 0);
        _expect(steps, new uint256[](0), abi.encodeWithSelector(IRecipes.InvalidReference.selector));
    }

    function test_EmptyMalformedTrailingAndUnknownSteps() public {
        (bool success,) = _compare(new bytes[](0), new bytes[](0), new uint256[](0));
        assertTrue(success);
        bytes[] memory steps = new bytes[](1);
        _expect(steps, new uint256[](0), abi.encodeWithSignature("Panic(uint256)", 0x32));
        for (uint8 operation; operation < 17; ++operation) {
            steps[0] = abi.encodePacked(operation);
            _compare(new bytes[](0), steps, new uint256[](0));
        }
        steps[0] = abi.encodePacked(uint8(255), hex"deadbeef");
        _expect(steps, new uint256[](0), abi.encodeWithSelector(IRecipes.InvalidOperation.selector));
        steps[0] = bytes.concat(_binary(OP_ADD, 7, 11), hex"deadbeef");
        bytes memory response;
        (success, response) = _compare(new bytes[](0), steps, new uint256[](0));
        assertTrue(success);
        assertEq(abi.decode(response, (uint256[]))[0], 18);
    }

    function testFuzz_MalformedPayloadsAgree(uint8 operation, bytes memory payload) public {
        if (payload.length > 512) return;
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(operation, payload);
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(RecipeDecodeTarget.tuple, (uint256(7), uint256(11))), new uint256[](0), 0);
        _compare(queries, steps, new uint256[](3));
    }

    function test_QueryFailureAndOffsetOrderingAgree() public {
        bytes[] memory queries = new bytes[](1);
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        queries[0] =
            _query(abi.encodeCall(RecipeDecodeTarget.fail, (hex"123456789abc")), new uint256[](0), type(uint256).max);
        (bool success, bytes memory response) = _compare(queries, steps, new uint256[](0));
        assertFalse(success);
        assertEq(response, hex"123456789abc");
        queries[0] = _query(abi.encodeCall(RecipeDecodeTarget.tuple, (uint256(7), uint256(11))), new uint256[](0), 33);
        (success, response) = _compare(queries, steps, new uint256[](0));
        assertFalse(success);
        assertEq(response, abi.encodeWithSelector(IRecipes.InvalidQuery.selector));
        queries[0] = _query(
            abi.encodeCall(RecipeDecodeTarget.tuple, (uint256(7), uint256(11))), new uint256[](0), type(uint256).max
        );
        (success, response) = _compare(queries, steps, new uint256[](0));
        assertFalse(success);
        assertEq(response, abi.encodeWithSignature("Panic(uint256)", 0x11));
        queries[0] = hex"deadbeef";
        _compare(queries, steps, new uint256[](0));
    }

    function _compare(bytes[] memory queries, bytes[] memory steps, uint256[] memory inputs)
        internal
        returns (bool success, bytes memory response)
    {
        uint256 snapshot = vm.snapshotState();
        (bool legacySuccess, bytes memory legacyResponse) =
            _harness.call(abi.encodeCall(RecipeDecodeHarness.legacy, (queries, steps, inputs)));
        bytes memory effects = _effects();
        assertTrue(vm.revertToState(snapshot));
        (success, response) = _harness.call(abi.encodeCall(RecipeDecodeHarness.proposed, (queries, steps, inputs)));
        assertEq(success, legacySuccess);
        assertEq(response, legacyResponse);
        assertEq(_effects(), effects);
    }

    function _effects() internal view returns (bytes memory) {
        return abi.encode(
            RecipeDecodeTarget(_target).value(),
            RecipeDecodeTarget(_target).calls(),
            RecipeDecodeTarget(_target).sender(),
            RecipeDecodeTarget(_target).receivedValue()
        );
    }

    function _expect(bytes[] memory steps, uint256[] memory inputs, bytes memory expected) internal {
        (bool success, bytes memory response) = _compare(new bytes[](0), steps, inputs);
        assertFalse(success);
        assertEq(response, expected);
    }

    function _input(uint256 index) internal pure returns (uint256) {
        return (uint256(SRC_INPUT) << 216) | index;
    }

    function _result(uint256 index) internal pure returns (uint256) {
        return (uint256(SRC_RESULT) << 216) | index;
    }

    function _binary(uint8 operation, uint256 a, uint256 b) internal pure returns (bytes memory) {
        return abi.encodePacked(operation, abi.encode(a, b));
    }

    function _query(bytes memory data, uint256[] memory bindings, uint256 offset) internal view returns (bytes memory) {
        return abi.encode(_target, data, bindings, offset);
    }

    function _call(uint8 operation, bytes memory data, uint256[] memory bindings, uint256 gate)
        internal
        view
        returns (bytes memory)
    {
        return operation == OP_CALL_IF
            ? abi.encodePacked(operation, abi.encode(gate, _target, data, bindings))
            : abi.encodePacked(operation, abi.encode(_target, data, bindings));
    }
}

/// @dev Same-address legacy/live oracle; the baseline interpreter body is frozen before production edits.
contract RecipeDecodeHarness is Recipes {
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
                (uint8 operation, bytes calldata operationData) = _step(steps[state.index]);
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

contract RecipeDecodeTarget {
    uint256 public value;
    uint256 public calls;
    address public sender;
    uint256 public receivedValue;

    function set(uint256 newValue) public payable {
        value = newValue;
        ++calls;
        sender = msg.sender;
        receivedValue = msg.value;
    }

    function tuple(uint256 a, uint256 b) public pure returns (uint256, uint256) {
        return (a, b);
    }

    function raw(bytes calldata data) public pure {
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, data.offset, data.length)
            return(p, data.length)
        }
    }

    function fail(bytes calldata data) public pure {
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, data.offset, data.length)
            revert(p, data.length)
        }
    }
}
