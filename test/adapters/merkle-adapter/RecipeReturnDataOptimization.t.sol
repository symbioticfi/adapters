// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Recipes} from "src/contracts/merkle-adapter/Recipes.sol";

import {
    IRecipes,
    OP_ADD,
    OP_CALL,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MAX,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
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
        return abi.encodePacked(operation, abi.encode(index));
    }

    function _call(address target, bytes memory data, bool) internal pure returns (bytes memory) {
        return abi.encodePacked(OP_CALL, abi.encode(target, data, new uint256[](0)));
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

/// @dev Same-address reference/current oracle using the audited instruction schema.
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
        State memory state = State({values: new uint256[](steps.length), index: 0});
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
        if (operation == OP_READ) {
            (address target, bytes memory data, uint256[] memory bindings, uint256 offset) =
                abi.decode(queries[abi.decode(operationData, (uint256))], (address, bytes, uint256[], uint256));
            _bind(data, bindings, steps, inputs, state);
            bytes memory result = target.functionStaticCall(data);
            if (offset + 32 > result.length) revert InvalidQuery();
            return uint256(result.load(offset));
        } else if (operation == OP_CALL) {
            (address target, bytes memory data, uint256[] memory bindings) =
                abi.decode(operationData, (address, bytes, uint256[]));
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
