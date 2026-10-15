// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ExecutingRecipe} from "../../../script/recipes/ExecutingRecipe.sol";
import {ImmutableFactory} from "../../../src/contracts/common/ImmutableFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {
    MerkleAdapterAssetReturnTarget,
    MerkleAdapterDelegatorMock,
    MerkleAdapterVaultMock
} from "../MerkleAdapter.t.sol";
import {RecipeExecutor} from "../../../src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {ActionMasker} from "../../../src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "../../../src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {
    IRecipes,
    OP_ADD,
    OP_APPROVE,
    OP_CALL,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MANAGE,
    OP_MAX,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
    OP_SATURATING_SUB,
    OP_SUB,
    SRC_INPUT,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {stdError} from "forge-std/StdError.sol";

contract RecipeExecutorTest is CapabilityTestBase {
    RecipeExecutor internal executor;
    RecipeApprovalToken internal token;
    RecipeTarget internal target;

    function setUp() public {
        token = new RecipeApprovalToken();
        _deployAdapter(address(token));
        executor = new RecipeExecutor(address(this), account);
        executor.setCaller(address(this));
        target = new RecipeTarget();
    }

    function test_MulticallConfiguresAndExecutesRecipe() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (17)), _none());
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(executor.setCaller, (address(this)));
        calls[1] = abi.encodeCall(executor.setRecipe, (recipe.queries, recipe.steps));
        calls[2] = abi.encodeCall(executor.execute, (recipe.queries, recipe.steps, new uint256[](0), new bytes[](0)));
        executor.multicall(calls);
        assertEq(target.value(), 17);
        assertEq(target.sender(), address(executor));
        assertEq(executor.recipeHash(), keccak256(abi.encode(recipe.queries, recipe.steps)));
    }

    function test_MulticallPreservesOwnerAndRollsBackConfiguration() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(0);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(executor.setCaller, (address(123)));
        calls[1] = abi.encodeCall(executor.execute, (recipe.queries, recipe.steps, new uint256[](0), new bytes[](0)));
        vm.prank(address(123));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(123)));
        executor.multicall(calls);
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.multicall(calls);
        assertEq(executor.caller(), address(this));
    }

    /// forge-config: default.isolate = true
    function test_CallUsesCommittedTemplateAndProducesNoUsableResult() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (17)), _none());
        uint256[] memory values = _run(recipe, new uint256[](0), new bytes[](0));
        vm.snapshotGasLastCall("RecipeExecutor", "executeCall");
        assertEq(target.value(), 17);
        assertEq(target.sender(), address(executor));
        assertEq(values.length, 1);
        assertEq(values[0], 0);
        vm.expectRevert(IRecipes.InvalidRuntime.selector);
        executor.execute(
            recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encodeCall(RecipeTarget.set, (99)))
        );
        assertEq(target.value(), 17);
    }

    function test_EmptyRecipeAndRuntimeLength() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(0);
        executor.setRecipe(recipe.queries, recipe.steps);
        assertEq(executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0)).length, 0);
        vm.expectRevert(IRecipes.InvalidRuntime.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](1));
    }

    /// forge-config: default.isolate = true
    function test_ConfigurationFactoryAndCurrentCommitment() public {
        ImmutableFactory factory = new ImmutableFactory(type(RecipeExecutor).creationCode);
        address instance = factory.create(abi.encode(address(this), account));
        assertTrue(factory.isEntity(instance));
        assertEq(RecipeExecutor(instance).account(), account);
        assertEq(RecipeExecutor(instance).owner(), address(this));
        assertEq(RecipeExecutor(instance).caller(), address(0));
        executor.setCaller(address(this));
        vm.snapshotGasLastCall("RecipeExecutor", "setCaller");
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (10)), _none());
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.snapshotGasLastCall("RecipeExecutor", "setRecipe");
        assertEq(executor.recipeHash(), keccak256(abi.encode(recipe.queries, recipe.steps)));
        assertEq(executor.recipeBlock(), block.number);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (11)), _none());
        vm.expectRevert(IRecipeExecutor.InvalidRecipe.selector);
        vm.startSnapshotGas("RecipeExecutor", "executeRecipeMismatch");
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        vm.stopSnapshotGas();
        assertEq(target.value(), 0);
        executor.setRecipe(recipe.queries, recipe.steps);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(target.value(), 11);
        recipe = _recipe(0);
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.snapshotGasLastCall("RecipeExecutor", "setRecipeClear");
        assertEq(executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0)).length, 0);
        vm.snapshotGasLastCall("RecipeExecutor", "executeEmpty");
    }

    /// forge-config: default.isolate = true
    function test_OwnerAndCallerBoundaries() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(0);
        vm.startPrank(address(123));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(123)));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(123)));
        executor.setCaller(address(123));
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        vm.startSnapshotGas("RecipeExecutor", "executeWrongCaller");
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        vm.stopSnapshotGas();
        vm.stopPrank();
        executor.setCaller(address(0));
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
    }

    /// forge-config: default.isolate = true
    function test_GasPackedArithmeticSequence() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(16);
        for (uint256 i; i < recipe.steps.length; ++i) {
            recipe.steps[i] = _binary(OP_ADD, i == 0 ? _literal(0) : _result(i - 1), _literal(1));
        }
        uint256[] memory values = _run(recipe, new uint256[](0), new bytes[](0));
        vm.snapshotGasLastCall("RecipeExecutor", "executePackedArithmeticSequence");
        assertEq(values.length, 16);
        assertEq(values[15], 16);
    }

    /// forge-config: default.isolate = true
    function test_GasPackedReadSequence() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(16);
        recipe.queries = new bytes[](1);
        recipe.queries[0] = _valueQuery();
        for (uint256 i; i < recipe.steps.length; ++i) {
            recipe.steps[i] = _read(0);
        }
        target.set(7);
        uint256[] memory values = _run(recipe, new uint256[](0), new bytes[](0));
        vm.snapshotGasLastCall("RecipeExecutor", "executePackedReadSequence");
        for (uint256 i; i < values.length; ++i) {
            assertEq(values[i], 7);
        }
    }

    /// forge-config: default.isolate = true
    function test_GasPackedApprovalSequence() public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _approvalRecipe(7);
        bytes[] memory steps = new bytes[](3);
        bytes[] memory runtime = new bytes[](3);
        for (uint256 i; i < steps.length; ++i) {
            steps[i] = recipe.steps[0];
            runtime[i] = data;
        }
        recipe.steps = steps;
        uint256[] memory values = _run(recipe, new uint256[](0), runtime);
        vm.snapshotGasLastCall("RecipeExecutor", "executePackedApprovalSequence");
        assertEq(token.allowance(account, address(target)), 7);
        assertEq(values, new uint256[](3));
    }

    function testFuzz_Arithmetic(uint128 x, uint128 y, uint128 divisor) public {
        divisor = uint128(bound(divisor, 1, type(uint128).max));
        ExecutingRecipe.Recipe memory recipe = _recipe(6);
        recipe.steps[0] = _binary(OP_ADD, _input(0), _literal(y));
        recipe.steps[1] = _binary(OP_SUB, _result(0), _literal(y));
        recipe.steps[2] = _binary(OP_MIN, _input(0), _literal(y));
        recipe.steps[3] = _mulDiv(_input(0), _literal(y), _literal(divisor));
        recipe.steps[4] = _binary(OP_SATURATING_SUB, _input(0), _literal(y));
        recipe.steps[5] = _binary(OP_MAX, _input(0), _literal(y));
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = x;
        uint256[] memory values = _run(recipe, inputs, new bytes[](0));
        assertEq(values[0], uint256(x) + y);
        assertEq(values[1], x);
        assertEq(values[2], x < y ? x : y);
        assertEq(values[3], uint256(x) * y / divisor);
        assertEq(values[4], x > y ? x - y : 0);
        assertEq(values[5], x > y ? x : y);
    }

    function testFuzz_MinMaxFullWidthResultsBindAndFeedArithmetic(uint256 a, uint256 b) public {
        ExecutingRecipe.Recipe memory recipe = _recipe(4);
        recipe.steps[0] = _binary(OP_MIN, _input(0), _input(1));
        recipe.steps[1] = _binary(OP_MAX, _input(0), _input(1));
        uint256[] memory bindings = new uint256[](2);
        bindings[0] = (uint256(4) << 224) | _result(1);
        bindings[1] = (uint256(36) << 224) | _result(0);
        recipe.steps[2] = _call(abi.encodeCall(RecipeTarget.setPair, (0, 0)), bindings);
        recipe.steps[3] = _binary(OP_SUB, _result(1), _result(0));
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = a;
        inputs[1] = b;
        uint256[] memory values = _run(recipe, inputs, new bytes[](0));
        assertEq(values[0], a < b ? a : b);
        assertEq(values[1], a > b ? a : b);
        assertEq(values[3], a > b ? a - b : b - a);
        assertEq(target.value(), values[1]);
        assertEq(target.other(), values[0]);
    }

    function test_MinMaxZeroEqualAndInvertedExtremes() public {
        uint256[5] memory a = [uint256(0), 0, type(uint256).max, type(uint256).max, 17];
        uint256[5] memory b = [uint256(0), type(uint256).max, 0, type(uint256).max, 17];
        for (uint256 i; i < a.length; ++i) {
            ExecutingRecipe.Recipe memory recipe = _recipe(2);
            recipe.steps[0] = _binary(OP_MIN, _input(0), _input(1));
            recipe.steps[1] = _binary(OP_MAX, _input(0), _input(1));
            uint256[] memory inputs = new uint256[](2);
            inputs[0] = a[i];
            inputs[1] = b[i];
            uint256[] memory values = _run(recipe, inputs, new bytes[](0));
            assertEq(values[0], a[i] < b[i] ? a[i] : b[i]);
            assertEq(values[1], a[i] > b[i] ? a[i] : b[i]);
        }
    }

    function test_FullWidthAndManyPriorResults() public {
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = type(uint256).max;
        inputs[1] = type(uint256).max - 1;
        ExecutingRecipe.Recipe memory recipe = _recipe(20);
        recipe.steps[0] = _binary(OP_ADD, _input(0), _literal(0));
        recipe.steps[1] = _binary(OP_SUB, _result(0), _input(1));
        for (uint256 i = 2; i < 20; ++i) {
            recipe.steps[i] = _binary(OP_ADD, _result(i - 1), _result(1));
        }
        uint256[] memory values = _run(recipe, inputs, new bytes[](0));
        assertEq(values[0], type(uint256).max);
        assertEq(values[19], 19);
        recipe = _recipe(1);
        recipe.steps[0] = _mulDiv(_input(0), _literal(1), _literal(1));
        assertEq(_run(recipe, inputs, new bytes[](0))[0], type(uint256).max);
    }

    /// forge-config: default.isolate = true
    function test_MulDivCheckedRoundingAndFailures() public {
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = type(uint256).max;
        inputs[1] = type(uint256).max - 1;
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = _mulDiv(_literal(7), _literal(3), _literal(2));
        uint256[] memory values = _run(recipe, inputs, new bytes[](0));
        vm.snapshotGasLastCall("RecipeExecutor", "executeMulDiv");
        assertEq(values[0], 10);
        // Even a representable quotient reverts when the intermediate product exceeds uint256.
        recipe.steps[0] = _mulDiv(_literal((1 << 200) + 1), _literal((1 << 100) + 1), _literal(1 << 100));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(recipe.queries, recipe.steps, inputs, new bytes[](0));
        recipe.steps[0] = _mulDiv(_input(0), _literal(2), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(recipe.queries, recipe.steps, inputs, new bytes[](0));
        recipe.steps[0] = _mulDiv(_input(0), _input(0), _literal(0));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(recipe.queries, recipe.steps, inputs, new bytes[](0));
        recipe.steps[0] = _mulDiv(_input(0), _literal(1), _literal(0));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.divisionError);
        executor.execute(recipe.queries, recipe.steps, inputs, new bytes[](0));
    }

    function testFuzz_MulDivPayloadBoundaries(uint8 truncatedLength, bytes memory trailing) public {
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = _mulDiv(_literal(7), _literal(3), _literal(2));
        bytes memory payload = Bytes.slice(recipe.steps[0], 1);
        recipe.steps[0] = abi.encodePacked(recipe.steps[0][0], bytes.concat(payload, trailing));
        assertEq(_run(recipe, new uint256[](0), new bytes[](0))[0], 10);
        uint256 length = bound(truncatedLength, 0, 95);
        assembly ("memory-safe") {
            mstore(payload, length)
        }
        recipe.steps[0] = abi.encodePacked(recipe.steps[0][0], payload);
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        // The denominator is one packed word; source 3 is invalid.
        recipe.steps[0] =
            abi.encodePacked(recipe.steps[0][0], abi.encode(_literal(7), _literal(3), (uint256(3) << 216) | 2));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.InvalidReference.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
    }

    function test_ArithmeticFailures() public {
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = type(uint256).max;
        inputs[1] = type(uint256).max - 1;
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = _binary(OP_ADD, _input(0), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(recipe.queries, recipe.steps, inputs, new bytes[](0));
        recipe.steps[0] = _binary(OP_SUB, _literal(0), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(recipe.queries, recipe.steps, inputs, new bytes[](0));
        recipe.steps[0] = _mulDiv(_literal(0), _literal(1), _literal(0));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.divisionError);
        executor.execute(recipe.queries, recipe.steps, inputs, new bytes[](0));
    }

    function test_ReferencesRequireEarlierValueInstructionsAndExistingInputs() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        for (uint256 operand; operand < 3; ++operand) {
            recipe.steps[0] = _mulDiv(
                operand == 0 ? _result(0) : _literal(1),
                operand == 1 ? _result(0) : _literal(1),
                operand == 2 ? _result(0) : _literal(1)
            );
            executor.setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(IRecipes.InvalidReference.selector);
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        }
        recipe.steps[0] = _binary(OP_ADD, _input(0), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe = _recipe(2);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (1)), _none());
        recipe.steps[1] = _binary(OP_ADD, _result(0), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.InvalidReference.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(target.value(), 0);
        recipe.steps[0] = _binary(OP_EQUAL, _literal(0), _literal(0));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.InvalidReference.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe.steps[0] = _binary(OP_ADD, _literal(0), _literal(0));
        assertEq(_run(recipe, new uint256[](0), new bytes[](0))[1], 1);
        recipe.steps[0] = _binary(OP_ADD, _result(1), _literal(0));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.InvalidReference.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
    }

    /// forge-config: default.isolate = true
    function test_GlobalResultsUseInstructionIndicesAcrossCallsAndChecks() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(7);
        recipe.queries = new bytes[](1);
        recipe.queries[0] = _valueQuery();
        recipe.steps[0] = _binary(OP_ADD, _literal(4), _literal(3));
        recipe.steps[1] = _binary(OP_EQUAL, _result(0), _literal(7));
        recipe.steps[2] = _call(abi.encodeCall(RecipeTarget.set, (999)), _bindings(4, _result(0)));
        recipe.steps[3] = _read(0);
        recipe.steps[4] = _binary(OP_ADD, _result(3), _literal(5));
        recipe.steps[5] = _call(abi.encodeCall(RecipeTarget.set, (999)), _bindings(4, _result(4)));
        recipe.steps[6] = _read(0);
        uint256[] memory values = _run(recipe, new uint256[](0), new bytes[](0));
        vm.snapshotGasLastCall("RecipeExecutor", "executeChecksAndBindings");
        assertEq(values.length, 7);
        assertEq(values[0], 7);
        assertEq(values[1], 0);
        assertEq(values[2], 0);
        assertEq(values[3], 7);
        assertEq(values[4], 12);
        assertEq(values[6], 12);
        assertEq(target.value(), 12);
    }

    /// forge-config: default.isolate = true
    function test_ChecksBeforePreventCallsAndChecksAfterRollback() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(2);
        for (uint256 comparison; comparison < 2; ++comparison) {
            bytes memory check = _binary(comparison == 0 ? OP_EQUAL : OP_LESS_OR_EQUAL, _literal(2), _literal(1));
            recipe.steps[0] = check;
            recipe.steps[1] = _call(abi.encodeCall(RecipeTarget.set, (17)), _none());
            executor.setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(IRecipes.CheckFailed.selector);
            if (comparison == 0) vm.startSnapshotGas("RecipeExecutor", "executeCheckBeforeFailure");
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
            if (comparison == 0) vm.stopSnapshotGas();
            assertEq(target.value(), 0);
            (recipe.steps[0], recipe.steps[1]) = (recipe.steps[1], recipe.steps[0]);
            executor.setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(IRecipes.CheckFailed.selector);
            if (comparison == 0) vm.startSnapshotGas("RecipeExecutor", "executeCheckAfterRollback");
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
            if (comparison == 0) vm.stopSnapshotGas();
            assertEq(target.value(), 0);
        }
        recipe.steps[0] = _binary(OP_LESS_OR_EQUAL, _literal(1), _literal(2));
        recipe.steps[1] = _binary(OP_LESS_OR_EQUAL, _literal(2), _literal(2));
        _run(recipe, new uint256[](0), new bytes[](0));
    }

    function test_BalanceDeltaDirectionsAndRollback() public {
        target.set(20);
        ExecutingRecipe.Recipe memory recipe = _recipe(4);
        recipe.queries = new bytes[](1);
        recipe.queries[0] = _valueQuery();
        recipe.steps[0] = _read(0);
        recipe.steps[1] = _call(abi.encodeCall(RecipeTarget.set, (7)), _none());
        recipe.steps[2] = _read(0);
        recipe.steps[3] = _binary(OP_SUB, _result(0), _result(2));
        assertEq(_run(recipe, new uint256[](0), new bytes[](0))[3], 13);
        recipe.steps[1] = _call(abi.encodeCall(RecipeTarget.set, (8)), _none());
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(target.value(), 7);
        recipe.steps[3] = _binary(OP_SUB, _result(2), _result(0));
        assertEq(_run(recipe, new uint256[](0), new bytes[](0))[3], 1);
    }

    /// forge-config: default.isolate = true
    function test_ManageZeroGuardConsumesRuntimeButKeepsFollowingChecks() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(3);
        recipe.steps[0] = abi.encodePacked(OP_MANAGE, abi.encode(_literal(0), new bytes32[](0), new uint256[][](0)));
        recipe.steps[1] = _binary(OP_ADD, _literal(5), _literal(2));
        recipe.steps[2] = _binary(OP_EQUAL, _result(1), _literal(7));
        uint256[] memory values = _run(recipe, new uint256[](0), _runtime(hex"ff"));
        vm.snapshotGasLastCall("RecipeExecutor", "executeManageZeroGuard");
        assertEq(values[1], 7);
        vm.expectRevert(stdError.indexOOBError);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        vm.expectRevert(IRecipes.InvalidRuntime.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](2));
        recipe.steps[2] = _binary(OP_EQUAL, _result(1), _literal(8));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(hex"ff"));
    }

    function test_SkippedManageKeepsFollowingApprovalRuntimeAligned() public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _approvalRecipe(100);
        bytes memory approval = recipe.steps[0];
        recipe = _recipe(4);
        recipe.steps[0] = abi.encodePacked(OP_MANAGE, abi.encode(_literal(0), new bytes32[](0), new uint256[][](0)));
        recipe.steps[1] = _binary(OP_ADD, _input(0), _literal(1));
        recipe.steps[2] = approval;
        recipe.steps[3] = _binary(OP_EQUAL, _result(1), _literal(7));
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 6;
        bytes[] memory runtime = new bytes[](2);
        runtime[0] = hex"ff";
        runtime[1] = data;

        uint256[] memory values = _run(recipe, inputs, runtime);

        assertEq(values[0], 0);
        assertEq(values[1], 7);
        assertEq(values[2], 0);
        assertEq(token.allowance(account, address(target)), 100);
        assertEq(token.lastApprover(), account);
    }

    function test_RuntimeCountsAndSkippedResultReferencesRollBackEarlierCalls() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(3);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (17)), _none());
        recipe.steps[1] = abi.encodePacked(OP_MANAGE, abi.encode(_literal(0), new bytes32[](0), new uint256[][](0)));
        recipe.steps[2] = _binary(OP_ADD, _literal(1), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.indexOOBError);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(target.value(), 0);
        vm.expectRevert(IRecipes.InvalidRuntime.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](2));
        assertEq(target.value(), 0);
        recipe.steps[2] = _binary(OP_ADD, _result(1), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.InvalidReference.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](1));
        assertEq(target.value(), 0);
    }

    /// forge-config: default.isolate = true
    function test_ReadMultipleBindingsWordSelectionAndStaticSafety() public {
        address queue = address(new RecipeParetoQueue(address(token)));
        uint256[] memory bindings = new uint256[](2);
        bindings[0] = (uint256(4) << 224) | _literal(uint256(uint160(address(adapter))));
        bindings[1] = (uint256(36) << 224) | _literal(17);
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.queries = new bytes[](1);
        recipe.steps[0] = _read(0);
        recipe.queries[0] =
            _query(queue, abi.encodeCall(RecipeParetoQueue.query, (address(0), uint256(0))), bindings, 0);
        assertEq(
            _run(recipe, new uint256[](0), new bytes[](0))[0],
            uint256(keccak256(abi.encode(address(adapter), uint256(17))))
        );
        recipe.queries[0] = _query(address(target), abi.encodeCall(RecipeTarget.pair, ()), _none(), 32);
        assertEq(_run(recipe, new uint256[](0), new bytes[](0))[0], 42);
        vm.snapshotGasLastCall("RecipeExecutor", "executeRead");
        recipe.queries[0] = _query(address(target), abi.encodeCall(RecipeTarget.pair, ()), _none(), 33);
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe.queries[0] = _query(address(target), abi.encodeCall(RecipeTarget.set, (17)), _none(), 0);
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert();
        executor.execute{gas: 500_000}(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(target.value(), 0);
    }

    function testFuzz_CallBindsMultipleCalculatedValues(uint128 first, uint128 second) public {
        uint256[] memory bindings = new uint256[](2);
        bindings[0] = (uint256(4) << 224) | _result(0);
        bindings[1] = (uint256(36) << 224) | _result(1);
        ExecutingRecipe.Recipe memory recipe = _recipe(3);
        recipe.steps[0] = _binary(OP_ADD, _input(0), _literal(3));
        recipe.steps[1] = _mulDiv(_input(1), _literal(2), _literal(1));
        recipe.steps[2] = _call(abi.encodeCall(RecipeTarget.setPair, (111, 222)), bindings);
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = first;
        inputs[1] = second;
        _run(recipe, inputs, new bytes[](0));
        assertEq(target.value(), uint256(first) + 3);
        assertEq(target.other(), uint256(second) * 2);
        assertEq(target.sender(), address(executor));
    }

    function test_BindingBoundsOrderingAndReferences() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        uint256[9] memory offsets =
            [uint256(0), 1, 3, 37, 68, 69, type(uint32).max - 32, type(uint32).max - 31, type(uint32).max];
        for (uint256 i; i < offsets.length; ++i) {
            recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.setPair, (0, 0)), _bindings(offsets[i], _literal(1)));
            executor.setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(IRecipes.InvalidCall.selector);
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        }
        uint256[] memory bindings = new uint256[](2);
        bindings[0] = (uint256(36) << 224) | _literal(1);
        bindings[1] = (uint256(4) << 224) | _literal(2);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.setPair, (0, 0)), bindings);
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.InvalidCall.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        bindings[0] = (uint256(4) << 224) | _literal(1);
        bindings[1] = (uint256(35) << 224) | _literal(2);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.setPair, (0, 0)), bindings);
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.InvalidCall.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (0)), _bindings(4, _result(0)));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.InvalidReference.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
    }

    function test_CommittedCallAllowsEmptyAndShortFallbackData() public {
        RecipeFallbackTarget fallbackTarget = new RecipeFallbackTarget();
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        for (uint256 i; i <= 4; ++i) {
            recipe.steps[0] = abi.encodePacked(
                OP_CALL, abi.encode(address(fallbackTarget), Bytes.slice(hex"12345678", 0, i), _none())
            );
            _run(recipe, new uint256[](0), new bytes[](0));
            assertEq(fallbackTarget.calls(), i + 1);
        }
    }

    /// forge-config: default.isolate = true
    function test_ManageUsesAdapterAndCurrentPermissions() public {
        IMerkleAccount.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _manageRecipe(action);
        _run(recipe, new uint256[](0), _runtime(data));
        vm.snapshotGasLastCall("RecipeExecutor", "executeManage");
        assertEq(target.value(), 7);
        assertEq(target.sender(), account);
        MerkleAccount(payable(account)).revokeRole(_leaf(action), address(executor));
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(data));
        MerkleAccount(payable(account)).grantRole(_leaf(action), address(executor));
        roots.setRoot(account, bytes32(uint256(123)));
        MerkleAccount(payable(account)).acceptRoot(bytes32(uint256(123)));
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(data));
    }

    function test_ManageDecodesRelocatedDataAndRequiresExactCount() public {
        IMerkleAccount.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (ExecutingRecipe.Recipe memory recipe, bytes memory canonical) = _manageRecipe(action);
        executor.setRecipe(recipe.queries, recipe.steps);
        bytes memory relocated = bytes.concat(canonical, Bytes.slice(abi.encode(action.data), 32));
        Bytes.replace(relocated, 160, abi.encode(canonical.length - 96));
        assertEq(abi.encode(abi.decode(relocated, (IMerkleAccount.Action[]))), canonical);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(relocated));
        assertEq(target.value(), 7);
        vm.expectRevert(IRecipes.InvalidRuntime.selector);
        executor.execute(
            recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(new IMerkleAccount.Action[](0)))
        );
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        recipe.steps[0] = abi.encodePacked(recipe.steps[0][0], abi.encode(_literal(1), leaves, new uint256[][](0)));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.InvalidRuntime.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(canonical));
    }

    function test_ManageVerifiesFinalBoundLeafAndRejectsNativeValue() public {
        IMerkleAccount.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (ExecutingRecipe.Recipe memory recipe,) = _manageRecipe(action);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = _bindings(4, _literal(7));
        recipe.steps[0] = abi.encodePacked(recipe.steps[0][0], abi.encode(_literal(1), leaves, bindings));
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        action.data = abi.encodeCall(RecipeTarget.set, (0));
        actions[0] = action;
        _run(recipe, new uint256[](0), _runtime(abi.encode(actions)));
        assertEq(target.value(), 7);
        bindings[0][0] = (uint256(4) << 224) | _literal(8);
        recipe.steps[0] = abi.encodePacked(recipe.steps[0][0], abi.encode(_literal(1), leaves, bindings));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(actions)));
        bindings[0][0] = (uint256(4) << 224) | _literal(7);
        recipe.steps[0] = abi.encodePacked(recipe.steps[0][0], abi.encode(_literal(1), leaves, bindings));
        actions[0].value = 1;
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(actions)));
    }

    /// forge-config: default.isolate = true
    function test_ManageBindsMultipleActionsAndPreservesOrder() public {
        address second = address(new RecipeTarget());
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = _action(address(target), abi.encodeCall(RecipeTarget.setPair, (0, 0)));
        actions[1] = _action(second, abi.encodeCall(RecipeTarget.setPair, (0, 0)));
        for (uint256 i; i < 2; ++i) {
            for (uint256 j = 4; j < 68; ++j) {
                actions[i].dataMask[j] = 0xff;
            }
        }
        bytes32[] memory leaves = _publishPair(actions);
        uint256[][] memory bindings = new uint256[][](2);
        for (uint256 i; i < 2; ++i) {
            bindings[i] = new uint256[](2);
            bindings[i][0] = (uint256(4) << 224) | _input(i);
            bindings[i][1] = (uint256(36) << 224) | _input(2);
        }
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = abi.encodePacked(OP_MANAGE, abi.encode(_literal(1), leaves, bindings));
        uint256[] memory inputs = new uint256[](3);
        inputs[0] = 7;
        inputs[1] = 9;
        inputs[2] = type(uint256).max;
        _run(recipe, inputs, _runtime(abi.encode(actions)));
        vm.snapshotGasLastCall("RecipeExecutor", "executeManageBoundActions");
        assertEq(target.value(), 7);
        assertEq(RecipeTarget(second).value(), 9);
        assertEq(target.other(), type(uint256).max);
        assertEq(target.sender(), account);
        (actions[0], actions[1]) = (actions[1], actions[0]);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        vm.startSnapshotGas("RecipeExecutor", "executeManageLeafMismatch");
        executor.execute(recipe.queries, recipe.steps, inputs, _runtime(abi.encode(actions)));
        vm.stopSnapshotGas();
        assertEq(target.value(), 7);
    }

    function test_ManageRejectsAnotherAuthorizedLeaf() public {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        actions[1] = _action(address(target), abi.encodeCall(RecipeTarget.set, (9)));
        bytes32[] memory leaves = _publishPair(actions);
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        bytes32[] memory selected = new bytes32[](1);
        selected[0] = leaves[0];
        recipe.steps[0] = abi.encodePacked(OP_MANAGE, abi.encode(_literal(1), selected, new uint256[][](1)));
        executor.setRecipe(recipe.queries, recipe.steps);
        IMerkleAccount.Action[] memory supplied = new IMerkleAccount.Action[](1);
        supplied[0] = actions[1];
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(supplied)));
        assertEq(target.value(), 0);
        supplied[0] = actions[0];
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(supplied)));
        assertEq(target.value(), 7);
    }

    function test_ManageCannotReleaseReservesEvenWhenLaterCallsWouldRestoreThem() public {
        address delegator = address(new MerkleAdapterDelegatorMock(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(delegator);
        deal(address(token), adapter.vault(), 50);
        MerkleAdapterDelegatorMock(delegator).allocate(address(adapter), 50);
        MerkleAdapterDelegatorMock(delegator).requestDeallocate(address(adapter), 50);
        assertEq(adapter.pendingDeallocation(), 50);
        address recipient = address(new MerkleAdapterAssetReturnTarget());
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = _action(address(adapter), abi.encodeCall(IMerkleAdapter.push, (1)));
        actions[1] = _action(
            recipient,
            abi.encodeCall(MerkleAdapterAssetReturnTarget.returnAsset, (IERC20(address(token)), address(adapter), 1))
        );
        bytes32[] memory leaves = _publishPair(actions);
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = abi.encodePacked(OP_MANAGE, abi.encode(_literal(1), leaves, new uint256[][](2)));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(actions)));
        assertEq(token.balanceOf(address(adapter)), 50);
        assertEq(token.balanceOf(recipient), 0);
        recipe = _recipe(2);
        bytes[] memory runtime = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            bytes32[] memory single = new bytes32[](1);
            single[0] = leaves[i];
            recipe.steps[i] = abi.encodePacked(OP_MANAGE, abi.encode(_literal(1), single, new uint256[][](1)));
            IMerkleAccount.Action[] memory supplied = new IMerkleAccount.Action[](1);
            supplied[0] = actions[i];
            runtime[i] = abi.encode(supplied);
        }
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(token.balanceOf(address(adapter)), 50);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_ManageNestedUnalignedWordsPreserveAbiHeaders() public {
        IMerkleAccount.Action memory action = _action(
            address(target), abi.encodeCall(RecipeTarget.setEncoded, (abi.encodeCall(RecipeTarget.setPair, (0, 0))))
        );
        for (uint256 i = 72; i < 136; ++i) {
            action.dataMask[i] = 0xff;
        }
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _manageRecipe(action);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](2);
        bindings[0][0] = (uint256(72) << 224) | _literal(23);
        bindings[0][1] = (uint256(104) << 224) | _literal(45);
        recipe.steps[0] = abi.encodePacked(recipe.steps[0][0], abi.encode(_literal(1), leaves, bindings));
        _run(recipe, new uint256[](0), _runtime(data));
        assertEq(target.value(), 23);
        assertEq(target.other(), 45);
        bindings[0] = _bindings(4, _literal(64));
        recipe.steps[0] = abi.encodePacked(recipe.steps[0][0], abi.encode(_literal(1), leaves, bindings));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(data));
    }

    /// forge-config: default.isolate = true
    function test_ApproveResetsClearsAndRunsFromAdapter() public {
        uint256 initialCalls = token.calls();
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _approvalRecipe(100);
        _run(recipe, new uint256[](0), _runtime(data));
        vm.snapshotGasLastCall("RecipeExecutor", "executeApprove");
        assertEq(token.allowance(account, address(target)), 100);
        assertEq(token.lastApprover(), account);
        _approvalAmount(recipe, 200);
        _run(recipe, new uint256[](0), _runtime(data));
        vm.snapshotGasLastCall("RecipeExecutor", "executeApproveReset");
        assertEq(token.calls(), initialCalls + 3);
        assertEq(token.allowance(account, address(target)), 200);
        _approvalAmount(recipe, 0);
        _run(recipe, new uint256[](0), _runtime(data));
        vm.snapshotGasLastCall("RecipeExecutor", "executeApproveClear");
        assertEq(token.calls(), initialCalls + 4);
        assertEq(token.allowance(account, address(target)), 0);
    }

    function testFuzz_ApprovalResolvesInputsAndPriorResultsBeforeReset(uint128 initial, uint128 replacement) public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _approvalRecipe(0);
        (,,, bytes32 leaf) = abi.decode(Bytes.slice(recipe.steps[0], 1), (uint256, address, address, bytes32));
        recipe = _recipe(3);
        recipe.steps[0] = _binary(OP_ADD, _input(0), _literal(1));
        recipe.steps[1] = abi.encodePacked(OP_APPROVE, abi.encode(_result(0), address(token), address(target), leaf));
        recipe.steps[2] = abi.encodePacked(OP_APPROVE, abi.encode(_input(1), address(token), address(target), leaf));
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = initial;
        inputs[1] = uint256(replacement) + 1;
        bytes[] memory runtime = new bytes[](2);
        runtime[0] = data;
        runtime[1] = data;
        uint256 beforeCalls = token.calls();
        vm.expectCall(address(token), abi.encodeCall(IERC20.approve, (address(target), uint256(initial) + 1)));
        vm.expectCall(address(token), abi.encodeCall(IERC20.approve, (address(target), uint256(replacement) + 1)));
        uint256[] memory values = _run(recipe, inputs, runtime);
        assertEq(values[0], uint256(initial) + 1);
        assertEq(token.calls(), beforeCalls + 3);
        assertEq(token.allowance(account, address(target)), uint256(replacement) + 1);
        assertEq(token.lastApprover(), account);
    }

    function testFuzz_TruncatedCommittedApprovalRollsBackPreviousCalls(uint8 length) public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory runtime) = _approvalRecipe(100);
        bytes memory approval = recipe.steps[0];
        approval = Bytes.slice(approval, 0, 1 + uint256(length) % 128);
        recipe = _recipe(2);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (17)), _none());
        recipe.steps[1] = approval;
        executor.setRecipe(recipe.queries, recipe.steps);
        uint256 beforeCalls = token.calls();
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(runtime));
        assertEq(target.value(), 0);
        assertEq(token.calls(), beforeCalls);
        assertEq(token.allowance(account, address(target)), 0);
    }

    function test_CommittedApprovalRejectsInvalidEnumAndNoncanonicalAddresses() public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory runtime) = _approvalRecipe(100);
        bytes memory canonical = Bytes.slice(recipe.steps[0], 1);
        uint256 beforeCalls = token.calls();
        for (uint256 field; field < 3; ++field) {
            recipe.steps[0] = abi.encodePacked(recipe.steps[0][0], bytes.concat(canonical));
            uint256 offset = 1 + field * 32;
            uint256 value = field == 0
                ? uint256(3) << 216
                : (uint256(1) << 160) | uint256(uint160(field == 1 ? address(token) : address(target)));
            Bytes.replace(recipe.steps[0], offset, abi.encode(value));
            executor.setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert();
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(runtime));
            assertEq(token.calls(), beforeCalls);
            assertEq(token.allowance(account, address(target)), 0);
        }
    }

    function test_CommittedApprovalTrailingBytesPreserveTokenSpenderAndLeaf() public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory runtime) = _approvalRecipe(100);
        recipe.steps[0] =
            abi.encodePacked(recipe.steps[0][0], bytes.concat(Bytes.slice(recipe.steps[0], 1), hex"deadbeef"));
        uint256 beforeCalls = token.calls();
        _run(recipe, new uint256[](0), _runtime(runtime));
        assertEq(token.allowance(account, address(target)), 100);
        assertEq(token.lastApprover(), account);
        assertEq(token.calls(), beforeCalls + 1);
        // A different committed spender still cannot use the original action leaf.
        Bytes.replace(recipe.steps[0], 65, abi.encode(address(0xbeef)));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(runtime));
        assertEq(token.allowance(account, address(0xbeef)), 0);
        assertEq(token.allowance(account, address(target)), 100);
    }

    /// forge-config: default.isolate = true
    function test_ApprovalFailureAfterSuccessfulResetRollsBackEntireRecipe() public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory runtime) = _approvalRecipe(100);
        _run(recipe, new uint256[](0), _runtime(runtime));
        _approvalAmount(recipe, 200);
        bytes memory approval = recipe.steps[0];
        recipe = _recipe(2);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (17)), _none());
        recipe.steps[1] = approval;
        executor.setRecipe(recipe.queries, recipe.steps);
        uint256 beforeCalls = token.calls();
        for (uint8 mode = 5; mode <= 7; ++mode) {
            token.setMode(mode);
            vm.expectCall(address(token), abi.encodeCall(IERC20.approve, (address(target), 0)));
            vm.expectCall(address(token), abi.encodeCall(IERC20.approve, (address(target), 200)));
            if (mode == 5) vm.expectRevert(IRecipeExecutor.ApprovalFailed.selector);
            else if (mode == 7) vm.expectRevert(RecipeApprovalToken.ApprovalRejected.selector);
            else vm.expectRevert();
            if (mode == 5) vm.startSnapshotGas("RecipeExecutor", "executeApproveResetFailure");
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(runtime));
            if (mode == 5) vm.stopSnapshotGas();
            assertEq(token.allowance(account, address(target)), 100);
            assertEq(token.calls(), beforeCalls);
            assertEq(target.value(), 0);
        }
    }

    function test_ApprovalResetRequiresAuthorizationForZeroAmount() public {
        IMerkleAccount.Action memory action =
            _action(address(token), abi.encodeCall(IERC20.approve, (address(target), 100)));
        _publish(action);
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] =
            abi.encodePacked(OP_APPROVE, abi.encode(_literal(100), address(token), address(target), _leaf(action)));
        bytes[] memory runtime = _runtime(abi.encode(action.dataMask, action.proof));
        _run(recipe, new uint256[](0), runtime);
        uint256 beforeCalls = token.calls();
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(token.allowance(account, address(target)), 100);
        assertEq(token.calls(), beforeCalls);
    }

    /// forge-config: default.isolate = true
    function test_ApprovalNoReturnFalseMalformedAndTrailingReturn() public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _approvalRecipe(100);
        token.setMode(1);
        _run(recipe, new uint256[](0), _runtime(data));
        vm.snapshotGasLastCall("RecipeExecutor", "executeApproveNoReturn");
        assertEq(token.allowance(account, address(target)), 100);
        _approvalAmount(recipe, 200);
        executor.setRecipe(recipe.queries, recipe.steps);
        for (uint8 mode = 2; mode <= 3; ++mode) {
            token.setMode(mode);
            uint256 beforeCalls = token.calls();
            if (mode == 2) vm.expectRevert(IRecipeExecutor.ApprovalFailed.selector);
            else vm.expectRevert();
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(data));
            assertEq(token.calls(), beforeCalls);
            assertEq(token.allowance(account, address(target)), 100);
        }
        token.setMode(4);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(data));
        vm.snapshotGasLastCall("RecipeExecutor", "executeApproveTrailingReturn");
        assertEq(token.allowance(account, address(target)), 200);
    }

    function test_ApprovalRejectsChangedMaskAndRollsBackPreviousCalls() public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _approvalRecipe(100);
        (bytes memory dataMask, bytes32[] memory proof) = abi.decode(data, (bytes, bytes32[]));
        dataMask[4] = 0xff;
        executor.setRecipe(recipe.queries, recipe.steps);
        uint256 beforeCalls = token.calls();
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(dataMask, proof)));
        assertEq(token.calls(), beforeCalls);
        assertEq(token.allowance(account, address(target)), 0);
        bytes memory approval = recipe.steps[0];
        recipe = _recipe(2);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (17)), _none());
        recipe.steps[1] = approval;
        executor.setRecipe(recipe.queries, recipe.steps);
        token.setMode(2);
        vm.expectRevert(IRecipeExecutor.ApprovalFailed.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(data));
        assertEq(target.value(), 0);
        assertEq(token.calls(), beforeCalls);
    }

    function test_ApprovalTupleRejectsTruncatedAndOuterStructEncoding() public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _approvalRecipe(100);
        executor.setRecipe(recipe.queries, recipe.steps);
        uint256 beforeCalls = token.calls();
        for (uint256 length; length < 64; ++length) {
            vm.expectRevert();
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(Bytes.slice(data, 0, length)));
        }
        vm.expectRevert();
        executor.execute(
            recipe.queries, recipe.steps, new uint256[](0), _runtime(bytes.concat(abi.encode(uint256(32)), data))
        );
        assertEq(token.calls(), beforeCalls);
        assertEq(token.allowance(account, address(target)), 0);
    }

    function test_ApprovalTupleCarriesCurrentMerkleProof() public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _approvalRecipe(100);
        (bytes memory dataMask,) = abi.decode(data, (bytes, bytes32[]));
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = _action(address(token), abi.encodeCall(IERC20.approve, (address(target), uint256(0))));
        actions[0].dataMask = dataMask;
        actions[1] = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        _publishPair(actions);
        _run(recipe, new uint256[](0), _runtime(abi.encode(dataMask, actions[0].proof)));
        assertEq(token.allowance(account, address(target)), 100);
        assertEq(token.lastApprover(), account);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(data));
        assertEq(token.allowance(account, address(target)), 100);
    }

    /// forge-config: default.isolate = true
    function test_ParetoCapturedEpochReceiptAndRollback() public {
        address queue = address(new RecipeParetoQueue(address(token)));
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = _action(address(token), abi.encodeCall(IERC20.approve, (queue, uint256(1 ether))));
        actions[1] = _action(queue, abi.encodeCall(RecipeParetoQueue.requestWithdraw, (uint256(1 ether))));
        bytes32[] memory leaves = _publishPair(actions);
        ExecutingRecipe.Recipe memory recipe = _recipe(7);
        recipe.queries = new bytes[](2);
        recipe.queries[0] = _query(queue, abi.encodeWithSignature("epochNumber()"), _none(), 0);
        recipe.queries[1] = _query(
            queue,
            abi.encodeWithSignature("userWithdrawalsEpochs(address,uint256)", account, 0),
            _bindings(36, _result(1)),
            0
        );
        recipe.steps[0] = _read(0);
        recipe.steps[1] = _binary(OP_ADD, _result(0), _literal(1));
        recipe.steps[2] = _read(1);
        recipe.steps[3] = abi.encodePacked(OP_MANAGE, abi.encode(_literal(1), leaves, new uint256[][](2)));
        recipe.steps[4] = _read(1);
        recipe.steps[5] = _binary(OP_SUB, _result(4), _result(2));
        recipe.steps[6] = _binary(OP_EQUAL, _result(5), _literal(1 ether));
        deal(address(token), account, 4 ether);
        _run(recipe, new uint256[](0), _runtime(abi.encode(actions)));
        vm.snapshotGasLastCall("RecipeExecutor", "executeNativeEpochReceipt");
        assertEq(RecipeParetoQueue(queue).userWithdrawalsEpochs(account, 1), 1 ether);
        RecipeParetoQueue(queue).setEpoch(9);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(actions)));
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(actions)));
        assertEq(RecipeParetoQueue(queue).userWithdrawalsEpochs(account, 10), 2 ether);
        for (uint256 multiplier; multiplier <= 2; multiplier += 2) {
            RecipeParetoQueue(queue).setReceiptMultiplier(multiplier);
            vm.expectRevert(IRecipes.CheckFailed.selector);
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(actions)));
            assertEq(token.balanceOf(account), 1 ether);
            assertEq(token.allowance(account, queue), 0);
            assertEq(RecipeParetoQueue(queue).userWithdrawalsEpochs(account, 10), 2 ether);
        }
    }

    function _recipe(uint256 length) internal pure returns (ExecutingRecipe.Recipe memory recipe) {
        recipe.queries = new bytes[](0);
        recipe.steps = new bytes[](length);
    }

    function _run(ExecutingRecipe.Recipe memory recipe, uint256[] memory inputs, bytes[] memory runtime)
        internal
        returns (uint256[] memory)
    {
        executor.setRecipe(recipe.queries, recipe.steps);
        return executor.execute(recipe.queries, recipe.steps, inputs, runtime);
    }

    function _runtime(bytes memory data) internal pure returns (bytes[] memory runtime) {
        runtime = new bytes[](1);
        runtime[0] = data;
    }

    function _literal(uint256 value) internal pure returns (uint256) {
        assertLe(value, type(uint216).max);
        return value;
    }

    function _input(uint256 index) internal pure returns (uint256) {
        assertLe(index, type(uint216).max);
        return (uint256(SRC_INPUT) << 216) | index;
    }

    function _result(uint256 index) internal pure returns (uint256) {
        assertLe(index, type(uint216).max);
        return (uint256(SRC_RESULT) << 216) | index;
    }

    function _binary(uint8 operation, uint256 a, uint256 b) internal pure returns (bytes memory) {
        return abi.encodePacked(operation, abi.encode(a, b));
    }

    function _mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (bytes memory) {
        return abi.encodePacked(OP_MUL_DIV, abi.encode(a, b, c));
    }

    function _read(uint256 index) internal pure returns (bytes memory) {
        return abi.encodePacked(OP_READ, abi.encode(index));
    }

    function _query(address recipient, bytes memory data, uint256[] memory bindings, uint256 offset)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(recipient, data, bindings, offset);
    }

    function _valueQuery() internal view returns (bytes memory) {
        return _query(address(target), abi.encodeWithSignature("value()"), _none(), 0);
    }

    function _none() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function _bindings(uint256 offset, uint256 value) internal pure returns (uint256[] memory bindings) {
        bindings = new uint256[](1);
        bindings[0] = (uint256(offset) << 224) | value;
    }

    function _call(bytes memory data, uint256[] memory bindings) internal view returns (bytes memory) {
        return abi.encodePacked(OP_CALL, abi.encode(address(target), data, bindings));
    }

    function _action(address recipient, bytes memory data) internal pure returns (IMerkleAccount.Action memory) {
        return IMerkleAccount.Action({
            target: recipient, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
    }

    function _leaf(IMerkleAccount.Action memory action) internal pure returns (bytes32) {
        return ActionMasker.mask(action.target, action.value, action.data, action.dataMask);
    }

    function _publish(IMerkleAccount.Action memory action) internal {
        bytes32 leaf = _leaf(action);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, address(executor));
    }

    function _manageRecipe(IMerkleAccount.Action memory action)
        internal
        returns (ExecutingRecipe.Recipe memory recipe, bytes memory data)
    {
        _publish(action);
        recipe = _recipe(1);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        recipe.steps[0] = abi.encodePacked(OP_MANAGE, abi.encode(_literal(1), leaves, new uint256[][](1)));
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = action;
        data = abi.encode(actions);
    }

    function _approvalRecipe(uint256 amount)
        internal
        returns (ExecutingRecipe.Recipe memory recipe, bytes memory data)
    {
        IMerkleAccount.Action memory action = _action(
            address(token), abi.encodeCall(IERC20.approve, (address(target), uint256(0)))
        );
        for (uint256 i = 36; i < 68; ++i) {
            action.dataMask[i] = 0xff;
        }
        _publish(action);
        recipe = _recipe(1);
        recipe.steps[0] =
            abi.encodePacked(OP_APPROVE, abi.encode(_literal(amount), address(token), address(target), _leaf(action)));
        data = abi.encode(action.dataMask, action.proof);
    }

    function _approvalAmount(ExecutingRecipe.Recipe memory recipe, uint256 amount) internal pure {
        (, address asset, address spender, bytes32 leaf) =
            abi.decode(Bytes.slice(recipe.steps[0], 1), (uint256, address, address, bytes32));
        recipe.steps[0] = abi.encodePacked(recipe.steps[0][0], abi.encode(_literal(amount), asset, spender, leaf));
    }

    function _publishPair(IMerkleAccount.Action[] memory actions) internal returns (bytes32[] memory leaves) {
        leaves = new bytes32[](2);
        for (uint256 i; i < 2; ++i) {
            leaves[i] = _leaf(actions[i]);
        }
        bytes32 root = leaves[0] < leaves[1]
            ? keccak256(abi.encodePacked(leaves[0], leaves[1]))
            : keccak256(abi.encodePacked(leaves[1], leaves[0]));
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        for (uint256 i; i < 2; ++i) {
            actions[i].proof = new bytes32[](1);
            actions[i].proof[0] = leaves[1 - i];
            MerkleAccount(payable(account)).grantRole(leaves[i], address(executor));
        }
    }
}

contract RecipeFallbackTarget {
    uint256 public calls;

    fallback() external {
        ++calls;
    }
}

contract RecipeTarget {
    uint256 public value;
    uint256 public other;
    address public sender;

    function echo(uint256 amount) public pure returns (uint256) {
        return amount;
    }

    function set(uint256 newValue) public {
        value = newValue;
        sender = msg.sender;
    }

    function setPair(uint256 first, uint256 second) public {
        value = first;
        other = second;
        sender = msg.sender;
    }

    function setEncoded(bytes calldata encoded) public {
        (value, other) = abi.decode(encoded[4:], (uint256, uint256));
        sender = msg.sender;
    }

    function pair() public pure returns (uint256, uint256) {
        return (7, 42);
    }
}

contract RecipeParetoQueue {
    address public immutable token;
    uint256 public epochNumber;
    uint256 public receiptMultiplier = 1;
    mapping(address => mapping(uint256 => uint256)) public userWithdrawalsEpochs;

    constructor(address newToken) {
        token = newToken;
    }

    function setEpoch(uint256 newEpoch) public {
        epochNumber = newEpoch;
    }

    function setReceiptMultiplier(uint256 newReceiptMultiplier) public {
        receiptMultiplier = newReceiptMultiplier;
    }

    function requestWithdraw(uint256 amount) public {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        userWithdrawalsEpochs[msg.sender][epochNumber + 1] += amount * receiptMultiplier;
    }

    function query(address account, uint256 epoch) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(account, epoch)));
    }
}

contract RecipeApprovalToken is ERC20 {
    error ApprovalRejected();

    uint256 public calls;
    uint8 public mode;
    address public lastApprover;

    constructor() ERC20("Recipe token", "R") {}

    function setMode(uint8 newMode) public {
        mode = newMode;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        require(amount == 0 || allowance(msg.sender, spender) == 0, "reset required");
        ++calls;
        lastApprover = msg.sender;
        super.approve(spender, amount);
        // Modes 5-7 let the reset succeed and fail only the following nonzero approval.
        if (amount != 0) {
            if (mode == 5) return false;
            if (mode == 6) {
                assembly ("memory-safe") {
                    mstore(0, 2)
                    return(0, 32)
                }
            }
            if (mode == 7) revert ApprovalRejected();
        }
        if (mode == 1) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (mode == 4) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(32, 123)
                return(0, 64)
            }
        }
        return mode != 2;
    }
}
