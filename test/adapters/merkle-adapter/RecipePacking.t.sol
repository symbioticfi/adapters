// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Recipes} from "src/contracts/merkle-adapter/Recipes.sol";

import {
    IRecipes as R,
    OP_ADD,
    OP_CALL,
    OP_CALL_IF,
    OP_MUL_DIV,
    OP_READ,
    OP_READ_WORD
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {Test} from "forge-std/Test.sol";

contract RecipePackingHarness is Recipes {
    function execute(bytes[] calldata queries, bytes[] calldata steps, uint256[] calldata inputs)
        public
        returns (uint256[] memory)
    {
        uint256 stepsLength = steps.length;
        State memory state;
        state.values = new uint256[](stepsLength);
        for (; state.index < stepsLength; ++state.index) {
            state.values[state.index] = _run(queries, steps, inputs, state);
        }
        return state.values;
    }
}

contract RecipePackingTest is Test {
    address internal harness = address(new RecipePackingHarness());
    uint256 public stored;

    function testFuzz_PackedLiterals(uint216 a, uint216 b) public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_ADD, abi.encode(uint256(a), uint256(b)));
        uint256[] memory values = RecipePackingHarness(harness).execute(new bytes[](0), steps, new uint256[](0));
        assertEq(values[0], uint256(a) + b);
    }

    function testFuzz_InputsAndResultsRetainAllBits(uint256 input) public {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = input;
        bytes[] memory steps = new bytes[](2);
        steps[0] = abi.encodePacked(OP_ADD, abi.encode(uint256(1) << 216, uint256(0)));
        steps[1] = abi.encodePacked(OP_ADD, abi.encode(uint256(2) << 216, uint256(0)));
        uint256[] memory values = RecipePackingHarness(harness).execute(new bytes[](0), steps, inputs);
        assertEq(values[0], input);
        assertEq(values[1], input);
    }

    function test_MaxLiteral() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_ADD, abi.encode(uint256(type(uint216).max), uint256(0)));
        uint256[] memory values = RecipePackingHarness(harness).execute(new bytes[](0), steps, new uint256[](0));
        assertEq(values[0], type(uint216).max);
    }

    function test_MaxInputAndResult() public {
        testFuzz_InputsAndResultsRetainAllBits(type(uint256).max);
    }

    function test_PackedMulDivDenominator() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_MUL_DIV, abi.encode(uint256(3), uint256(7), uint256(2)));
        uint256[] memory values = RecipePackingHarness(harness).execute(new bytes[](0), steps, new uint256[](0));
        assertEq(values[0], 10);
    }

    function testFuzz_BindingsRetainAllBits(uint256 input) public {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = input;
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = (uint256(4) << 224) | uint256(1) << 216;
        bytes[] memory queries = new bytes[](1);
        queries[0] = abi.encode(address(this), abi.encodeCall(this.echo, (uint256(0))), bindings, uint256(0));
        bytes[] memory steps = new bytes[](2);
        steps[0] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        bindings[0] = (uint256(4) << 224) | (uint256(2) << 216);
        steps[1] =
            abi.encodePacked(OP_CALL, abi.encode(address(this), abi.encodeCall(this.set, (uint256(0))), bindings));
        uint256[] memory values = RecipePackingHarness(harness).execute(queries, steps, inputs);
        assertEq(values[0], input);
        assertEq(stored, input);
    }

    function test_BindingWordRetainsFullInput() public {
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = (uint256(4) << 224) | (uint256(1) << 216);
        bytes[] memory queries = new bytes[](1);
        queries[0] = abi.encode(address(this), abi.encodeCall(this.echo, (uint256(0))), bindings, uint256(0));
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = type(uint256).max;
        uint256[] memory values = RecipePackingHarness(harness).execute(queries, steps, inputs);
        assertEq(values[0], type(uint256).max);
    }

    function test_MaxInputAndResultBindings() public {
        testFuzz_BindingsRetainAllBits(type(uint256).max);
    }

    function testFuzz_InvalidBindingSourceRejected(uint8 source, uint216 value) public {
        source = uint8(bound(source, 3, type(uint8).max));
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = (uint256(4) << 224) | (uint256(source) << 216) | value;
        bytes[] memory queries = new bytes[](1);
        queries[0] = abi.encode(address(this), abi.encodeCall(this.echo, (uint256(0))), bindings, uint256(0));
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        vm.expectRevert(R.InvalidReference.selector);
        RecipePackingHarness(harness).execute(queries, steps, new uint256[](0));
    }

    function test_MaxBindingOffsetRejected() public {
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = uint256(type(uint32).max) << 224;
        bytes[] memory steps = new bytes[](1);
        steps[0] =
            abi.encodePacked(OP_CALL, abi.encode(address(this), abi.encodeCall(this.set, (uint256(0))), bindings));
        vm.expectRevert(R.InvalidCall.selector);
        RecipePackingHarness(harness).execute(new bytes[](0), steps, new uint256[](0));
    }

    function testFuzz_InvalidSourceRejected(uint8 source, uint216 value) public {
        source = uint8(bound(source, 3, type(uint8).max));
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_ADD, abi.encode((uint256(source) << 216) | value, uint256(0)));
        vm.expectRevert(R.InvalidReference.selector);
        RecipePackingHarness(harness).execute(new bytes[](0), steps, new uint256[](0));
    }

    function testFuzz_InvalidSourceCannotReferenceEarlierResult(uint8 source) public {
        source = uint8(bound(source, 3, type(uint8).max));
        bytes[] memory steps = new bytes[](2);
        steps[0] = abi.encodePacked(OP_ADD, abi.encode(uint256(1), uint256(2)));
        steps[1] = abi.encodePacked(OP_ADD, abi.encode(uint256(source) << 216, uint256(0)));
        vm.expectRevert(R.InvalidReference.selector);
        RecipePackingHarness(harness).execute(new bytes[](0), steps, new uint256[](0));
    }

    function testFuzz_InvalidOperationRejected(uint8 operation) public {
        operation = uint8(bound(operation, OP_CALL_IF + 1, type(uint8).max));
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(operation, abi.encode(uint256(0), uint256(0)));
        vm.expectRevert(R.InvalidOperation.selector);
        RecipePackingHarness(harness).execute(new bytes[](0), steps, new uint256[](0));
    }

    function test_EmptyStepRejected() public {
        bytes[] memory steps = new bytes[](1);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x32)));
        RecipePackingHarness(harness).execute(new bytes[](0), steps, new uint256[](0));
    }

    function testFuzz_TruncatedPayloadRejected(uint8 length) public {
        length = uint8(bound(length, 0, 63));
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_ADD, new bytes(length));
        vm.expectRevert();
        RecipePackingHarness(harness).execute(new bytes[](0), steps, new uint256[](0));
    }

    function test_MaxInputIndexRejected() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_ADD, abi.encode((uint256(1) << 216) | type(uint216).max, uint256(0)));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x32)));
        RecipePackingHarness(harness).execute(new bytes[](0), steps, new uint256[](0));
    }

    function test_MaxResultIndexRejected() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_ADD, abi.encode((uint256(2) << 216) | type(uint216).max, uint256(0)));
        vm.expectRevert(R.InvalidReference.selector);
        RecipePackingHarness(harness).execute(new bytes[](0), steps, new uint256[](0));
    }

    function set(uint256 value) public {
        stored = value;
    }

    function echo(uint256 value) public pure returns (uint256) {
        return value;
    }
}
