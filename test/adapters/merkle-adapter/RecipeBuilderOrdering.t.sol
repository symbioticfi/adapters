// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {Token} from "test/mocks/Token.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {
    OP_APPROVE,
    OP_CALL,
    OP_CLEAR_APPROVAL,
    OP_EQUAL,
    OP_MANAGE,
    OP_READ,
    OP_READ_CACHED,
    OP_READ_WORD,
    OP_SUB,
    SRC_INPUT,
    SRC_LITERAL,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {Test} from "forge-std/Test.sol";

contract RecipeBuilderOrderingTest is Test {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    function test_RawActionsKeepFollowingHelperRuntimeSlotsAligned() public pure {
        uint8[3] memory operations = [OP_MANAGE, OP_APPROVE, OP_CLEAR_APPROVAL];
        for (uint256 i; i < operations.length; ++i) {
            ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
            builder.read(ExecutingRecipe.Read({target: address(1), data: hex"12345678", offset: 0}));
            bytes memory payload = operations[i] == OP_MANAGE
                ? abi.encode(uint256(0), new bytes32[](0), new uint256[][](0))
                : operations[i] == OP_APPROVE
                    ? abi.encode(uint256(0), address(1), address(2), bytes32(0))
                    : abi.encode(address(1), address(2), bytes32(0));
            assertEq(builder.instruction(operations[i], payload), 1);
            builder.call(address(1), hex"12345678", new uint256[](0));
            assertEq(builder.manage(new bytes32[](0), 0), 1);
            assertEq(builder.approve(address(1), address(2), bytes32(0), 0), 2);
            assertEq(builder.clearApproval(address(1), address(2), bytes32(0), true), 3);
            assertEq(builder.clearApproval(address(1), address(2), bytes32(0), false), 4);
            ExecutingRecipe.Recipe memory recipe = builder.finish();
            assertEq(recipe.steps[1], abi.encodePacked(operations[i], payload));
            uint256[] memory runtimeSteps = ExecutingRecipe.runtimeSteps(recipe);
            assertEq(runtimeSteps.length, 5);
            assertEq(runtimeSteps[0], 1);
            assertEq(runtimeSteps[1], 3);
            assertEq(runtimeSteps[2], 4);
            assertEq(runtimeSteps[3], 5);
            assertEq(runtimeSteps[4], 6);
        }
    }

    function test_ReadsAndCalculationsKeepInstructionOrderAcrossActions() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        ExecutingRecipe.Query memory query =
            ExecutingRecipe.query(ExecutingRecipe.Read({target: address(1), data: hex"12345678", offset: 0}));
        uint256 before = builder.readQuery(query);
        uint256 runtime = builder.manage(new bytes32[](0), builder.literal(0));
        uint256 afterValue = builder.readQuery(query);
        uint256 delta = builder.binary(OP_SUB, afterValue, before);
        builder.check(OP_EQUAL, delta, builder.literal(0));
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        assertEq(uint216(before), 0);
        assertEq(runtime, 0);
        assertEq(uint216(afterValue), 2);
        assertEq(uint216(delta), 3);
        assertEq(recipe.steps.length, 5);
        assertEq(recipe.queries.length, 1);
        assertEq(Bytes.slice(recipe.steps[0], 1), Bytes.slice(recipe.steps[2], 1));
        assertEq(ExecutingRecipe.runtimeSteps(recipe)[0], 1);
    }

    function test_SharedQueriesCommitBindingsAndReturnOffsets() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        ExecutingRecipe.Query memory query = ExecutingRecipe.query(
            ExecutingRecipe.Read({
                target: address(1), data: abi.encodeWithSelector(bytes4(0x12345678), uint256(0)), offset: 0
            })
        );
        query.bindings = new uint256[](1);
        query.bindings[0] = (uint256(4) << 224) | builder.input(0);
        builder.readQuery(query);
        query.bindings[0] = (uint256(4) << 224) | builder.input(1);
        builder.readQuery(query);
        query.offset = 1;
        builder.readQuery(query);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        assertEq(recipe.queries.length, 3);
        (,, uint256[] memory bindings, uint256 offset) =
            abi.decode(recipe.queries[0], (address, bytes, uint256[], uint256));
        assertEq(uint216(bindings[0]), 0);
        (,, bindings, offset) = abi.decode(recipe.queries[1], (address, bytes, uint256[], uint256));
        assertEq(uint216(bindings[0]), 1);
        (,, bindings, offset) = abi.decode(recipe.queries[2], (address, bytes, uint256[], uint256));
        assertEq(offset, 1);
    }

    function testFuzz_PackedOperandsPreserveSourceAndValue(uint216 value) public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        assertEq(builder.literal(value), value);
        assertEq(builder.input(value), (uint256(SRC_INPUT) << 216) | value);
        assertEq(ExecutingRecipe.result(value), (uint256(SRC_RESULT) << 216) | value);
        assertEq(builder.literal(type(uint216).max), type(uint216).max);
        assertEq(uint216(builder.input(type(uint216).max)), type(uint216).max);
        assertEq(uint216(ExecutingRecipe.result(type(uint216).max)), type(uint216).max);
    }

    function test_CachedTupleUsesOneQueryAndKeepsRuntimeSlots() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        ExecutingRecipe.Query memory query =
            ExecutingRecipe.query(ExecutingRecipe.Read({target: address(1), data: hex"12345678", offset: 32}));
        query.bindings = new uint256[](1);
        query.bindings[0] = ExecutingRecipe.binding(4, builder.input(0));
        uint256 first = builder.readCachedQuery(query);
        uint256 second = builder.readWord(first, 0);
        builder.check(OP_EQUAL, second, second);
        assertEq(builder.mulDiv(first, 0, 1), 0);
        assertEq(builder.mulDiv(second, 0, 1), 0);
        uint256 runtime = builder.manage(new bytes32[](0), 0);
        uint256 third = builder.readWord(first, 1);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        assertEq(recipe.queries.length, 1);
        assertEq(recipe.steps.length, 4);
        assertEq(uint8(recipe.steps[0][0]), OP_READ_CACHED);
        assertEq(uint8(recipe.steps[1][0]), OP_READ_WORD);
        (uint256 producer, uint256 offset) = abi.decode(Bytes.slice(recipe.steps[1], 1), (uint256, uint256));
        assertEq(producer, 0);
        assertEq(offset, 0);
        assertEq(uint216(third), 3);
        assertEq(runtime, 0);
        assertEq(ExecutingRecipe.runtimeSteps(recipe)[0], 2);
    }

    function test_OrdinaryReadsStayFreshBetweenCachedWords() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        ExecutingRecipe.Read memory query = ExecutingRecipe.Read({target: address(1), data: hex"12345678", offset: 0});
        uint256 cached = builder.readCached(query);
        builder.read(query);
        builder.readWord(cached, 32);
        builder.read(query);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        assertEq(recipe.queries.length, 1);
        assertEq(uint8(recipe.steps[1][0]), OP_READ);
        assertEq(uint8(recipe.steps[3][0]), OP_READ);
    }

    function testFuzz_CachedWordRejectsInvalidProducer(uint256 operand) public {
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.invalidCachedWord(operand);
    }

    function test_CachedWordRejectsReplacedProducer() public {
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.expiredCachedWord();
    }

    function testFuzz_PackedOperandsRejectOverflow(uint256 value) public {
        value = bound(value, uint256(type(uint216).max) + 1, type(uint256).max);
        for (uint8 source; source < 3; ++source) {
            vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(216), value));
            this.encodeOperand(source, value);
        }
    }

    function testFuzz_PackedBindingsPreserveOffsetAndOperand(uint32 offset, uint224 srcAndValue) public pure {
        uint256 binding = ExecutingRecipe.binding(offset, srcAndValue);
        assertEq(binding >> 224, offset);
        assertEq(uint224(binding), srcAndValue);
        assertEq(ExecutingRecipe.binding(type(uint32).max, type(uint224).max), type(uint256).max);
    }

    function testFuzz_PackedBindingsRejectOffsetOverflow(uint256 offset) public {
        offset = bound(offset, uint256(type(uint32).max) + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(32), offset));
        this.encodeBinding(offset, 0);
    }

    function testFuzz_PackedBindingsRejectOperandOverflow(uint256 srcAndValue) public {
        srcAndValue = bound(srcAndValue, uint256(type(uint224).max) + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(224), srcAndValue)
        );
        this.encodeBinding(4, srcAndValue);
    }

    function encodeBinding(uint256 offset, uint256 srcAndValue) public pure returns (uint256) {
        return ExecutingRecipe.binding(offset, srcAndValue);
    }

    function encodeOperand(uint8 source, uint256 value) public pure returns (uint256) {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        if (source == SRC_LITERAL) return builder.literal(value);
        if (source == SRC_INPUT) return builder.input(value);
        return ExecutingRecipe.result(value);
    }

    function test_ManageBindingsMustMatchLeaves() public {
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.invalidBindings();
    }

    function testFuzz_InstructionRejectsUnknownOperation(uint8 operation) public {
        operation = uint8(bound(operation, OP_READ_WORD + 1, type(uint8).max));
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.invalidInstruction(operation);
    }

    function testFuzz_RuntimeStepsRejectUnknownOperation(uint8 operation) public {
        operation = uint8(bound(operation, OP_READ_WORD + 1, type(uint8).max));
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.invalidRuntimeSteps(operation);
    }

    function invalidInstruction(uint8 operation) public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        builder.instruction(operation, "");
    }

    function invalidRuntimeSteps(uint8 operation) public pure {
        ExecutingRecipe.Recipe memory recipe;
        recipe.steps = new bytes[](1);
        recipe.steps[0] = abi.encodePacked(operation);
        ExecutingRecipe.runtimeSteps(recipe);
    }

    function invalidBindings() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        builder.manage(new bytes32[](1), builder.literal(1), new uint256[][](0));
    }

    function invalidCachedWord(uint256 operand) public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        builder.binary(OP_SUB, 0, 1);
        builder.readWord(operand, 0);
    }

    function expiredCachedWord() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        ExecutingRecipe.Read memory query = ExecutingRecipe.Read({target: address(1), data: hex"12345678", offset: 0});
        uint256 first = builder.readCached(query);
        builder.readCached(query);
        builder.readWord(first, 32);
    }
}

contract RecipeBuilderRuntimeTest is CapabilityTestBase {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    function test_SkippedRawActionsConsumeSlotsBeforeHelperApproval() public {
        address token = address(new Token("Builder runtime"));
        _deployAdapter(token);
        address executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(executor).setCaller(address(this));
        address spender = address(0xbeef);
        bytes memory data = abi.encodeCall(IERC20.approve, (spender, uint256(0)));
        bytes memory mask = new bytes(data.length);
        for (uint256 i = 36; i < 68; ++i) {
            mask[i] = 0xff;
        }
        bytes32 leaf = MerkleAdapterVerifier.leaf(token, 0, data, mask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, executor);

        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        builder.instruction(OP_MANAGE, abi.encode(uint256(0), new bytes32[](0), new uint256[][](0)));
        builder.manage(new bytes32[](0), 0);
        builder.instruction(OP_CLEAR_APPROVAL, abi.encode(token, spender, bytes32(0)));
        uint256 approval = builder.approve(token, spender, leaf, 7);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        uint256[] memory runtimeSteps = ExecutingRecipe.runtimeSteps(recipe);
        assertEq(runtimeSteps.length, 4);
        bytes[] memory runtime = new bytes[](runtimeSteps.length);
        runtime[approval] = abi.encode(mask, new bytes32[](0));
        RecipeExecutor(executor).setRecipe(recipe.queries, recipe.steps);
        RecipeExecutor(executor).execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(IERC20(token).allowance(account, spender), 7);
        assertEq(approval, 3);
        for (uint256 i; i < runtimeSteps.length; ++i) {
            assertEq(runtimeSteps[i], i);
        }
    }
}
