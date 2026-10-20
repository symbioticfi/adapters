// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
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
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {Test, stdError} from "forge-std/Test.sol";
import {Token} from "test/mocks/Token.sol";

contract RecipeOptimizationTest is Test {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    address internal _executor;
    uint256 public stored;
    uint256 public managedCalls;

    function setUp() public {
        _executor = address(new RecipeExecutor(address(this), address(this)));
        RecipeExecutor(_executor).setCaller(address(this));
    }

    function test_ConstantChainAndProvenChecksEmitNoInstructions() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 value = builder.binary(OP_ADD, builder.literal(3), builder.literal(4));
        value = builder.mulDiv(value, builder.literal(3), builder.literal(2));
        builder.check(OP_EQUAL, value, builder.literal(10));
        builder.check(OP_LESS_OR_EQUAL, value, builder.literal(11));
        assertEq(value, 10);
        assertEq(builder.finish().steps.length, 0);
    }

    function testFuzz_ConstantArithmetic(uint104 a, uint104 b, uint104 denominator) public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        assertEq(builder.binary(OP_ADD, a, b), uint256(a) + b);
        assertEq(builder.binary(OP_SUB, a > b ? a : b, a > b ? b : a), a > b ? a - b : b - a);
        assertEq(builder.binary(OP_SATURATING_SUB, a, b), a > b ? a - b : 0);
        assertEq(builder.binary(OP_MIN, a, b), a < b ? a : b);
        assertEq(builder.binary(OP_MAX, a, b), a > b ? a : b);
        assertEq(builder.mulDiv(a, b, uint256(denominator) + 1), uint256(a) * b / (uint256(denominator) + 1));
        assertEq(builder.finish().steps.length, 0);
    }

    function test_IdentitiesReuseEvaluatedResultsWithoutNarrowing() public {
        stored = type(uint256).max;
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 value = builder.read(_storedQuery());
        assertEq(builder.binary(OP_ADD, value, 0), value);
        assertEq(builder.binary(OP_ADD, 0, value), value);
        assertEq(builder.binary(OP_SUB, value, 0), value);
        assertEq(builder.binary(OP_SATURATING_SUB, value, 0), value);
        assertEq(builder.binary(OP_MAX, value, 0), value);
        assertEq(builder.binary(OP_MAX, 0, value), value);
        assertEq(builder.binary(OP_MIN, value, value), value);
        assertEq(builder.binary(OP_MAX, value, value), value);
        assertEq(builder.mulDiv(value, 1, 1), value);
        assertEq(builder.mulDiv(1, value, 1), value);
        builder.check(OP_EQUAL, value, value);
        builder.check(OP_LESS_OR_EQUAL, value, value);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        assertEq(recipe.steps.length, 1);
        uint256[] memory values = _run(recipe, new uint256[](0));
        assertEq(values[uint216(value)], type(uint256).max);
    }

    function test_ReusesArithmeticAndChecksAcrossCallsButKeepsFreshReads() public {
        stored = 10;
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 beforeValue = builder.read(_storedQuery());
        uint256 sum = builder.binary(OP_ADD, beforeValue, 1);
        builder.check(OP_LESS_OR_EQUAL, sum, 20);
        builder.call(address(this), abi.encodeCall(this.set, (uint256(40))), new uint256[](0));
        assertEq(builder.binary(OP_ADD, beforeValue, 1), sum);
        builder.check(OP_LESS_OR_EQUAL, sum, 20);
        uint256 afterValue = builder.read(_storedQuery());
        uint256 freshSum = builder.binary(OP_ADD, afterValue, 1);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        assertEq(recipe.steps.length, 6);
        uint256[] memory values = _run(recipe, new uint256[](0));
        assertEq(values[uint216(sum)], 11);
        assertEq(values[uint216(freshSum)], 41);
        assertEq(stored, 40);
    }

    function test_DuplicateReadsWithoutActionsStillExecuteTwice() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        ExecutingRecipe.Read memory query = ExecutingRecipe.Read({target: address(1), data: hex"12345678", offset: 0});
        uint256 first = builder.read(query);
        uint256 second = builder.read(query);
        assertNotEq(first, second);
        assertEq(builder.finish().steps.length, 2);
    }

    function test_BalancesReuseOnlyTheSameTokenAndAccountUntilAnAction() public {
        address token = address(new Token("Balance"));
        address otherToken = address(new Token("Other balance"));
        IERC20(token).transfer(_executor, 10);
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 beforeValue = builder.balance(token, _executor);
        builder.read(_storedQuery());
        assertEq(builder.balance(token, _executor), beforeValue);
        assertNotEq(builder.balance(token, address(this)), beforeValue);
        assertNotEq(builder.balance(otherToken, _executor), beforeValue);
        builder.call(token, abi.encodeCall(IERC20.transfer, (address(this), 3)), new uint256[](0));
        uint256 afterValue = builder.balance(token, _executor);
        assertNotEq(afterValue, beforeValue);
        assertEq(builder.balance(token, _executor), afterValue);
        assertNotEq(builder.readQuery(ExecutingRecipe.balanceQuery(token, _executor)), afterValue);
        uint256[] memory values = _run(builder.finish(), new uint256[](0));
        assertEq(values[uint216(beforeValue)], 10);
        assertEq(values[uint216(afterValue)], 7);
    }

    function test_EveryActionIsABalanceBarrierIncludingRawAndZeroGatedActions() public pure {
        for (uint8 operation = OP_MANAGE; operation <= OP_CALL; ++operation) {
            for (uint256 raw; raw < 2; ++raw) {
                ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
                uint256 beforeValue = builder.balance(address(1), address(2));
                if (raw > 0) builder.instruction(operation, "");
                else if (operation == OP_MANAGE) builder.manage(new bytes32[](0), 0);
                else if (operation == OP_APPROVE) builder.approve(address(1), address(3), bytes32(0), 0);
                else if (operation == OP_CALL) builder.call(address(1), "", new uint256[](0));
                else builder.clearApproval(address(1), address(3), bytes32(0));
                uint256 afterValue = builder.balance(address(1), address(2));
                assertNotEq(afterValue, beforeValue);
                assertEq(builder.balance(address(1), address(2)), afterValue);
                assertEq(builder.finish().steps.length, 3);
            }
        }
    }

    function test_ConditionalReadsPreserveBalanceCacheAndResolveFullWidthResults() public {
        address token = address(new Token("Conditional"));
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 balance = builder.balance(token, _executor);
        uint256 value = builder.readIf(ExecutingRecipe.query(_storedQuery()), builder.input(0), balance);
        assertEq(builder.balance(token, _executor), balance);
        assertEq(builder.mulDiv(value, 0, 1), 0);
        assertEq(builder.binary(OP_ADD, value, 0), value);
        builder.check(OP_LESS_OR_EQUAL, 0, value);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        assertEq(recipe.steps.length, 7);
        uint256[] memory inputs = new uint256[](1);
        uint256[] memory values = _run(recipe, inputs);
        assertEq(values[uint216(value)], 0);
        stored = type(uint256).max;
        inputs[0] = 1;
        values = _run(recipe, inputs);
        assertEq(values[uint216(value)], type(uint256).max);
    }

    function test_BalanceReuseDoesNotDecodeMalformedRawReadsDuringBuild() public pure {
        for (uint256 i; i < 2; ++i) {
            ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
            uint256 value = builder.balance(address(1), address(2));
            builder.instruction(OP_READ, i == 0 ? bytes("") : abi.encode(type(uint256).max));
            assertEq(builder.balance(address(1), address(2)), value);
            assertEq(builder.finish().steps.length, 2);
        }
    }

    function test_FullyFundedPushStillRequiresReadableReserveQueries() public {
        address token = address(new Token("Push"));
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        ExecutingRecipe.Funding memory funding;
        funding.account = address(this);
        funding.asset = token;
        funding.adapter = address(0xdead);
        funding.pushLeaf = bytes32(uint256(1));
        funding.skipUnusedReads = true;
        funding.sources = new ExecutingRecipe.Source[](0);
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = IERC20(token).balanceOf(address(this));
        builder.fund(funding, builder.input(0));
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = hex"deadbeef";
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert();
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, inputs, runtime);
    }

    function test_ThreeFundingSourcesRemoveTwoRepeatedBalanceReads() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        ExecutingRecipe.Funding memory funding;
        funding.account = address(4);
        funding.asset = address(5);
        funding.sources = new ExecutingRecipe.Source[](3);
        for (uint256 i; i < 3; ++i) {
            funding.sources[i].capacity =
                ExecutingRecipe.Read({target: address(uint160(i + 1)), data: hex"12345678", offset: 0});
            funding.sources[i].leaves = new bytes32[](0);
            funding.sources[i].amountOffsets = new uint256[][](0);
        }
        builder.fund(funding, builder.input(0));
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        uint256 balances;
        for (uint256 i; i < recipe.steps.length; ++i) {
            if (uint8(recipe.steps[i][0]) != OP_READ) continue;
            uint256 index = abi.decode(Bytes.slice(recipe.steps[i], 1), (uint256));
            (address target,,,) = abi.decode(recipe.queries[index], (address, bytes, uint256[], uint256));
            if (target == funding.asset) ++balances;
        }
        assertEq(balances, 4);
        assertEq(ExecutingRecipe.runtimeSteps(recipe).length, 3);
    }

    function test_PreparationRunsEvenWhenNoFundsAreNeeded() public {
        address token = address(new Token("Preparation"));
        IERC20(token).transfer(_executor, 10);
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 beforeValue = builder.balance(token, _executor);
        ExecutingRecipe.Funding memory funding;
        funding.account = _executor;
        funding.asset = token;
        funding.sources = new ExecutingRecipe.Source[](1);
        funding.sources[0].prepare =
            ExecutingRecipe.Call({target: token, data: abi.encodeCall(IERC20.transfer, (address(this), 3))});
        funding.sources[0].capacity = _storedQuery();
        builder.fund(funding, 0);
        uint256 afterValue = builder.balance(token, _executor);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        assertEq(uint8(recipe.steps[1][0]), OP_CALL);
        assertEq(ExecutingRecipe.runtimeSteps(recipe).length, 1);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        uint256[] memory values =
            RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](1));
        assertEq(values[uint216(beforeValue)], 10);
        assertEq(values[uint216(afterValue)], 7);
        assertEq(IERC20(token).balanceOf(_executor), 7);
    }

    function test_InvalidSourcePreparationAndCapacityConfigurationReverts() public {
        for (uint256 i; i < 4; ++i) {
            ExecutingRecipe.Funding memory funding;
            funding.sources = new ExecutingRecipe.Source[](i == 0 ? 2 : 1);
            if (i == 1) funding.sources[0].capacity.data = hex"12345678";
            if (i == 2) funding.sources[0].capacity.offset = 1;
            if (i == 3) funding.sources[0].prepare.data = hex"12345678";
            vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
            this.buildFunding(funding);
        }
    }

    function buildFunding(ExecutingRecipe.Funding memory funding) public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        builder.fund(funding, 0);
    }

    function testFuzz_ZeroMultiplicationAndLowerBoundsUseValidatedInputs(uint256 input) public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 value = builder.input(0);
        builder.check(OP_EQUAL, value, value);
        assertEq(builder.mulDiv(value, 0, 1), 0);
        assertEq(builder.mulDiv(0, value, 1), 0);
        builder.check(OP_LESS_OR_EQUAL, 0, value);
        uint256 result = builder.read(_storedQuery());
        builder.check(OP_LESS_OR_EQUAL, 0, result);
        assertEq(builder.finish().steps.length, 2);
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = input;
        _run(builder.finish(), inputs);
    }

    function test_HigherInputIndexProvesLowerInputsExistIncludingMulDivDenominator() public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        builder.instruction(OP_MUL_DIV, abi.encode(uint256(0), uint256(0), builder.input(2)));
        assertEq(builder.mulDiv(builder.input(1), 0, 1), 0);
        builder.check(OP_LESS_OR_EQUAL, 0, builder.input(0));
        assertEq(builder.finish().steps.length, 1);
        uint256[] memory inputs = new uint256[](3);
        inputs[2] = 1;
        _run(builder.finish(), inputs);
    }

    function test_InputProofIgnoresUnusedWordsAndConditionalBindings() public pure {
        for (uint256 i; i < 3; ++i) {
            ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
            uint256 operand = builder.input(9);
            if (i == 0) builder.instruction(OP_ADD, abi.encode(uint256(0), uint256(0), operand));
            if (i == 1) builder.instruction(OP_ADD, abi.encode(operand));
            if (i == 2) {
                uint256[][] memory bindings = new uint256[][](1);
                bindings[0] = new uint256[](1);
                bindings[0][0] = ExecutingRecipe.binding(4, operand);
                builder.manage(new bytes32[](1), 0, bindings);
            }
            assertNotEq(builder.mulDiv(operand, 0, 1), 0);
            assertEq(builder.finish().steps.length, 2);
        }
    }

    function test_ZeroOptimizationsPreserveOperandAndDenominatorFailures() public {
        for (uint256 i; i < 8; ++i) {
            ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
            uint256 operand = i < 2 ? builder.input(0) : ExecutingRecipe.result(0);
            if (i >= 4 && i < 6) operand = uint256(3) << 216;
            if (i >= 6) builder.call(address(this), abi.encodeCall(this.set, (uint256(99))), new uint256[](0));
            if (i % 2 == 0) builder.mulDiv(operand, 0, 1);
            else builder.check(OP_LESS_OR_EQUAL, 0, operand);
            ExecutingRecipe.Recipe memory recipe = builder.finish();
            RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(i < 2 ? stdError.indexOOBError : abi.encodeWithSelector(IRecipes.InvalidReference.selector));
            RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
            assertEq(stored, 0);
        }
        for (uint256 i; i < 2; ++i) {
            ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
            uint256 value = builder.input(0);
            builder.check(OP_EQUAL, value, value);
            builder.mulDiv(value, 0, i == 0 ? 0 : value);
            ExecutingRecipe.Recipe memory recipe = builder.finish();
            assertEq(recipe.steps.length, 2);
            RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(stdError.divisionError);
            RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](1), new bytes[](0));
        }
    }

    function test_OptimizationKeepsRuntimeIndicesAndBoundValues() public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 value = builder.binary(OP_ADD, 3, 4);
        assertEq(builder.manage(new bytes32[](0), 0), 0);
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = ExecutingRecipe.binding(4, value);
        builder.call(address(this), abi.encodeCall(this.set, (uint256(0))), bindings);
        assertEq(builder.manage(new bytes32[](0), 0), 1);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        assertEq(recipe.steps.length, 3);
        uint256[] memory runtimeSteps = ExecutingRecipe.runtimeSteps(recipe);
        assertEq(runtimeSteps[0], 0);
        assertEq(runtimeSteps[1], 2);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](2));
        assertEq(stored, 7);
    }

    function test_WideConstantsRemainRuntimeResults() public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 value = builder.binary(OP_ADD, type(uint216).max, 1);
        uint256 multiplied = builder.mulDiv(type(uint216).max, 2, 1);
        assertEq(uint8(value >> 216), SRC_RESULT);
        assertEq(uint8(multiplied >> 216), SRC_RESULT);
        uint256[] memory values = _run(builder.finish(), new uint256[](0));
        assertEq(values[uint216(value)], uint256(type(uint216).max) + 1);
        assertEq(values[uint216(multiplied)], uint256(type(uint216).max) * 2);
    }

    function test_ConstantsAtTheLiteralLimitStillFold() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        assertEq(builder.binary(OP_ADD, type(uint216).max - 1, 1), type(uint216).max);
        assertEq(builder.mulDiv(type(uint216).max, 2, 2), type(uint216).max);
        assertEq(builder.mulDiv(type(uint216).max, 0, 1), 0);
        assertEq(builder.finish().steps.length, 0);
    }

    function test_OperandsWithIgnoredOffsetBitsRemainBindable() public {
        stored = type(uint256).max;
        for (uint256 i; i < 2; ++i) {
            ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
            uint256 operand = ExecutingRecipe.binding(4, builder.read(_storedQuery()));
            uint256 value = i == 0 ? builder.binary(OP_ADD, operand, 0) : builder.mulDiv(operand, 1, 1);
            uint256[] memory bindings = new uint256[](1);
            bindings[0] = ExecutingRecipe.binding(4, value);
            builder.call(address(this), abi.encodeCall(this.set, (uint256(0))), bindings);
            _run(builder.finish(), new uint256[](0));
            assertEq(stored, type(uint256).max);
        }
    }

    function test_BoundQueryUsesFoldedOperandAndReusedCalculation() public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 value = builder.binary(OP_ADD, 3, 4);
        ExecutingRecipe.Query memory query = ExecutingRecipe.query(
            ExecutingRecipe.Read({target: address(this), data: abi.encodeCall(this.echo, (uint256(0))), offset: 0})
        );
        query.bindings = new uint256[](1);
        query.bindings[0] = ExecutingRecipe.binding(4, value);
        uint256 readValue = builder.readQuery(query);
        uint256 sum = builder.binary(OP_ADD, readValue, 1);
        query.bindings[0] = ExecutingRecipe.binding(4, builder.binary(OP_ADD, readValue, 1));
        uint256 secondRead = builder.readQuery(query);
        uint256[] memory values = _run(builder.finish(), new uint256[](0));
        assertEq(values[uint216(readValue)], 7);
        assertEq(values[uint216(sum)], 8);
        assertEq(values[uint216(secondRead)], 8);
    }

    function test_ConstantFailuresRemainAtRuntime() public {
        for (uint256 i; i < 4; ++i) {
            ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
            if (i == 0) builder.binary(OP_SUB, 0, 1);
            if (i == 1) builder.mulDiv(1, 1, 0);
            if (i == 2) builder.mulDiv(type(uint216).max, type(uint216).max, type(uint216).max);
            if (i == 3) builder.check(OP_EQUAL, 0, 1);
            ExecutingRecipe.Recipe memory recipe = builder.finish();
            assertEq(recipe.steps.length, 1);
            RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(
                i == 1
                    ? stdError.divisionError
                    : i == 3 ? abi.encodeWithSelector(IRecipes.CheckFailed.selector) : stdError.arithmeticError
            );
            RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        }
    }

    function test_UnresolvedInputsAndInvalidResultsAreNotOptimizedAway() public {
        for (uint256 i; i < 8; ++i) {
            ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
            uint256 operand = i < 2 ? builder.input(0) : ExecutingRecipe.result(0);
            if (i >= 4 && i < 6) operand = uint256(3) << 216;
            if (i >= 6) builder.call(address(this), abi.encodeCall(this.set, (uint256(99))), new uint256[](0));
            if (i % 2 == 0) builder.binary(OP_ADD, operand, 0);
            else builder.check(OP_EQUAL, operand, operand);
            ExecutingRecipe.Recipe memory recipe = builder.finish();
            assertEq(recipe.steps.length, i >= 6 ? 2 : 1);
            RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(i < 2 ? stdError.indexOOBError : abi.encodeWithSelector(IRecipes.InvalidReference.selector));
            RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
            assertEq(stored, 0);
        }
    }

    function test_MulDivDoesNotCancelOverflowingFactors() public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 value = builder.read(_storedQuery());
        builder.mulDiv(value, 2, 2);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        stored = type(uint256).max;
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.arithmeticError);
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
    }

    function testFuzz_OptimizedProgramsMatchRawExecution(uint256 seed, uint256 input) public {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = input;
        // Exercise both successful bounded arithmetic and full-width overflow/revert paths.
        for (uint256 i; i < 2; ++i) {
            ExecutingRecipe.Recipe memory raw = _program(seed, false);
            ExecutingRecipe.Recipe memory optimized = _program(seed, true);
            assertLe(optimized.steps.length, raw.steps.length);
            stored = 0;
            RecipeExecutor(_executor).setRecipe(raw.queries, raw.steps);
            (bool rawSuccess, bytes memory rawResult) =
                _executor.call(abi.encodeCall(RecipeExecutor.execute, (raw.queries, raw.steps, inputs, new bytes[](0))));
            uint256 expected = stored;
            stored = 0;
            RecipeExecutor(_executor).setRecipe(optimized.queries, optimized.steps);
            (bool optimizedSuccess, bytes memory optimizedResult) = _executor.call(
                abi.encodeCall(RecipeExecutor.execute, (optimized.queries, optimized.steps, inputs, new bytes[](0)))
            );
            assertEq(optimizedSuccess, rawSuccess);
            if (!rawSuccess) assertEq(optimizedResult, rawResult);
            assertEq(stored, expected);
            inputs[0] = uint64(input);
        }
    }

    function testFuzz_MixedProgramsMatchRawReadsActionsAndRuntime(uint256 seed, uint256 input) public {
        _assertMixedPrograms(seed, input);
    }

    function test_MixedProgramsPreserveMaximumWidthValuesAndRollback() public {
        _assertMixedPrograms(type(uint256).max, type(uint256).max);
    }

    /// forge-config: default.isolate = true
    function test_GasOptimizedArithmetic() public {
        ExecutingRecipe.Recipe memory raw = _arithmeticRecipe(false);
        ExecutingRecipe.Recipe memory optimized = _arithmeticRecipe(true);
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 31;
        uint256 snapshot = vm.snapshotState();
        _run(raw, inputs);
        uint256 rawGas = vm.lastCallGas().gasTotalUsed;
        vm.snapshotGasLastCall("RecipeOptimization", "arithmeticRaw");
        assertEq(stored, 38);
        assertTrue(vm.revertToState(snapshot));
        _run(optimized, inputs);
        uint256 optimizedGas = vm.lastCallGas().gasTotalUsed;
        vm.snapshotGasLastCall("RecipeOptimization", "arithmeticOptimized");
        assertEq(stored, 38);
        assertLt(optimizedGas, rawGas);
        assertLt(abi.encode(optimized.queries, optimized.steps).length, abi.encode(raw.queries, raw.steps).length);
        emit log_named_uint("Raw execution gas", rawGas);
        emit log_named_uint("Optimized execution gas", optimizedGas);
        emit log_named_uint("Raw instructions", raw.steps.length);
        emit log_named_uint("Optimized instructions", optimized.steps.length);
        emit log_named_uint("Raw recipe bytes", abi.encode(raw.queries, raw.steps).length);
        emit log_named_uint("Optimized recipe bytes", abi.encode(optimized.queries, optimized.steps).length);
    }

    function record(uint256[] memory values) public {
        stored = uint256(keccak256(abi.encode(values)));
    }

    function echo(uint256 value) public pure returns (uint256) {
        return value;
    }

    function echoStored(uint256 value) public view returns (uint256, uint256) {
        return (stored, value);
    }

    // The executor checks committed leaves and bindings; this test account dispatches the managed calls.
    function manage(IMerkleAccount.Action[] calldata actions) public returns (bytes[] memory responses) {
        assertEq(msg.sender, _executor);
        responses = new bytes[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            (bool success, bytes memory response) = actions[i].target.call(actions[i].data);
            if (!success) {
                assembly ("memory-safe") { revert(add(response, 32), mload(response)) }
            }
            responses[i] = response;
            ++managedCalls;
        }
    }

    function set(uint256 value) public {
        stored = value;
    }

    function _storedQuery() internal view returns (ExecutingRecipe.Read memory) {
        return ExecutingRecipe.Read({target: address(this), data: abi.encodeCall(this.stored, ()), offset: 0});
    }

    function _assertMixedPrograms(uint256 seed, uint256 input) internal {
        address token = address(new Token("Mixed program"));
        uint256 initialCash = 32 + (seed >> 8) % 128;
        uint256 amount = seed % 16 + 1;
        IERC20(token).transfer(_executor, initialCash);
        uint256 initialAccountCash = IERC20(token).balanceOf(address(this));
        stored = seed;
        managedCalls = 0;
        bytes[] memory runtime = new bytes[](4);
        // Zero gates must consume their slots without decoding these invalid payloads.
        runtime[0] = hex"deadbeef";
        runtime[2] = hex"badc0de0";
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _mixedAction(token, _executor);
        runtime[1] = abi.encode(actions);
        actions[0] = _mixedAction(token, address(0xbeef));
        runtime[3] = abi.encode(actions);

        for (uint256 failure; failure < 3; ++failure) {
            uint256[] memory inputs = new uint256[](1);
            inputs[0] = failure == 2 ? type(uint256).max : input;
            ExecutingRecipe.Recipe memory raw = _mixedProgram(seed, token, false, failure);
            ExecutingRecipe.Recipe memory optimized = _mixedProgram(seed, token, true, failure);
            assertLt(optimized.steps.length, raw.steps.length);
            uint256[] memory rawSlots = ExecutingRecipe.runtimeSteps(raw);
            uint256[] memory optimizedSlots = ExecutingRecipe.runtimeSteps(optimized);
            assertEq(rawSlots.length, runtime.length);
            assertEq(optimizedSlots.length, runtime.length);
            for (uint256 i; i < runtime.length; ++i) {
                assertEq(uint8(raw.steps[rawSlots[i]][0]), OP_MANAGE);
                assertEq(uint8(optimized.steps[optimizedSlots[i]][0]), OP_MANAGE);
            }

            uint256 snapshot = vm.snapshotState();
            RecipeExecutor(_executor).setRecipe(raw.queries, raw.steps);
            (bool rawSuccess, bytes memory rawResult) =
                _executor.call(abi.encodeCall(RecipeExecutor.execute, (raw.queries, raw.steps, inputs, runtime)));
            bytes32 rawState = _mixedState(token);
            assertTrue(vm.revertToState(snapshot));
            RecipeExecutor(_executor).setRecipe(optimized.queries, optimized.steps);
            (bool optimizedSuccess, bytes memory optimizedResult) = _executor.call(
                abi.encodeCall(RecipeExecutor.execute, (optimized.queries, optimized.steps, inputs, runtime))
            );
            assertEq(optimizedSuccess, rawSuccess);
            assertEq(_mixedState(token), rawState);
            if (failure == 0) {
                assertTrue(rawSuccess);
                uint256[] memory expected = new uint256[](14);
                expected[0] = seed;
                expected[1] = initialCash;
                expected[2] = initialCash;
                expected[3] = input;
                expected[4] = amount;
                expected[5] = initialCash - amount;
                expected[6] = input;
                expected[7] = input;
                expected[8] = seed;
                expected[9] = initialCash;
                expected[10] = amount;
                expected[11] = initialAccountCash - amount - 1;
                expected[12] = initialCash;
                expected[13] = input;
                assertEq(stored, uint256(keccak256(abi.encode(expected))));
                assertEq(managedCalls, 2);
                assertEq(IERC20(token).balanceOf(_executor), initialCash);
                assertEq(IERC20(token).balanceOf(address(this)), initialAccountCash - amount - 1);
                assertEq(IERC20(token).balanceOf(address(0xbeef)), amount + 1);
            } else {
                assertFalse(rawSuccess);
                assertEq(optimizedResult, rawResult);
                assertEq(
                    rawResult,
                    failure == 1 ? abi.encodeWithSelector(IRecipes.CheckFailed.selector) : stdError.arithmeticError
                );
                assertEq(stored, seed);
                assertEq(managedCalls, 0);
                assertEq(IERC20(token).balanceOf(_executor), initialCash);
                assertEq(IERC20(token).balanceOf(address(this)), initialAccountCash);
                assertEq(IERC20(token).balanceOf(address(0xbeef)), 0);
            }
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function _mixedState(address token) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                stored,
                managedCalls,
                IERC20(token).balanceOf(_executor),
                IERC20(token).balanceOf(address(this)),
                IERC20(token).balanceOf(address(0xbeef))
            )
        );
    }

    function _mixedProgram(uint256 seed, address token, bool optimize, uint256 failure)
        internal
        view
        returns (ExecutingRecipe.Recipe memory)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256[] memory values = new uint256[](14);
        values[0] = builder.read(_storedQuery());
        values[1] = _mixedBalance(builder, optimize, token, _executor);
        values[2] = _mixedBalance(builder, optimize, token, _executor);
        uint256 input = _binary(builder, optimize, OP_ADD, builder.input(0), 0);
        ExecutingRecipe.Query memory query = ExecutingRecipe.query(
            ExecutingRecipe.Read({target: address(this), data: abi.encodeCall(this.echo, (uint256(0))), offset: 0})
        );
        query.bindings = new uint256[](1);
        query.bindings[0] = ExecutingRecipe.binding(4, _binary(builder, optimize, OP_MAX, input, input));
        values[3] = builder.readQuery(query);
        values[4] = _binary(builder, optimize, OP_ADD, seed % 16, 1);

        builder.manage(new bytes32[](0), 0);
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = ExecutingRecipe.binding(36, values[4]);
        builder.call(token, abi.encodeCall(IERC20.transfer, (address(this), uint256(0))), bindings);
        values[5] = _mixedBalance(builder, optimize, token, _executor);
        bindings[0] = ExecutingRecipe.binding(4, values[3]);
        builder.call(address(this), abi.encodeCall(this.set, (uint256(0))), bindings);
        values[6] = builder.read(_storedQuery());

        query.data = abi.encodeCall(this.echoStored, (uint256(0)));
        query.bindings[0] = ExecutingRecipe.binding(4, _binary(builder, optimize, OP_ADD, values[0], 0));
        values[7] = builder.readQuery(query);
        query.offset = 32;
        values[8] = builder.readQuery(query);
        _mixedManage(builder, token, _executor, values[4]);
        values[9] = _mixedBalance(builder, optimize, token, _executor);
        bindings[0] = ExecutingRecipe.binding(4, values[4]);
        builder.call(address(this), abi.encodeCall(this.set, (uint256(0))), bindings);
        values[10] = builder.read(_storedQuery());
        builder.manage(new bytes32[](0), 0);
        _mixedManage(builder, token, address(0xbeef), _binary(builder, optimize, OP_ADD, values[4], 1));
        values[11] = _mixedBalance(builder, optimize, token, address(this));
        values[12] = _mixedBalance(builder, optimize, token, _executor);
        values[13] = _binary(builder, optimize, OP_ADD, values[3], 0);

        if (failure == 1) {
            uint256 different = _binary(builder, optimize, OP_ADD, values[4], 1);
            if (optimize) builder.check(OP_EQUAL, values[10], different);
            else builder.instruction(OP_EQUAL, abi.encode(values[10], different));
        } else if (failure == 2) {
            if (optimize) builder.mulDiv(input, 2, 2);
            else builder.instruction(OP_MUL_DIV, abi.encode(input, uint256(2), uint256(2)));
        }
        bindings = new uint256[](values.length);
        for (uint256 i; i < values.length; ++i) {
            bindings[i] = ExecutingRecipe.binding(68 + 32 * i, values[i]);
        }
        builder.call(address(this), abi.encodeCall(this.record, (new uint256[](values.length))), bindings);
        return builder.finish();
    }

    function _mixedBalance(ExecutingRecipe.Builder memory builder, bool optimize, address token, address account)
        internal
        pure
        returns (uint256)
    {
        return
            optimize ? builder.balance(token, account) : builder.readQuery(ExecutingRecipe.balanceQuery(token, account));
    }

    function _mixedManage(ExecutingRecipe.Builder memory builder, address token, address recipient, uint256 amount)
        internal
        pure
    {
        IMerkleAccount.Action memory action = _mixedAction(token, recipient);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = ActionMasker.mask(action.target, action.value, action.data, action.dataMask);
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](1);
        bindings[0][0] = ExecutingRecipe.binding(36, amount);
        builder.manage(leaves, 1, bindings);
    }

    function _mixedAction(address token, address recipient)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        bytes memory data = abi.encodeCall(IERC20.transfer, (recipient, uint256(0)));
        bytes memory mask = new bytes(data.length);
        for (uint256 i = 36; i < 68; ++i) {
            mask[i] = 0xff;
        }
        return IMerkleAccount.Action({target: token, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }

    function _program(uint256 seed, bool optimize) internal view returns (ExecutingRecipe.Recipe memory) {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256[] memory operands = new uint256[](17);
        uint256[] memory bindings = new uint256[](operands.length);
        operands[0] = builder.input(0);
        bindings[0] = ExecutingRecipe.binding(68, operands[0]);
        for (uint256 i = 1; i < operands.length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint8 operation = uint8(1 + seed % 6);
            uint256 a = operands[(seed >> 8) % i];
            uint256 b = (seed >> 16) % 3 == 0 ? operands[(seed >> 24) % i] : (seed >> 32) % 8;
            if (operation == OP_MUL_DIV) {
                uint256 denominator = (seed >> 40) % 8;
                operands[i] = optimize
                    ? builder.mulDiv(a, b, denominator)
                    : ExecutingRecipe.result(builder.instruction(operation, abi.encode(a, b, denominator)));
            } else {
                operands[i] = _binary(builder, optimize, operation, a, b);
            }
            // Duplicate checks test reuse after results have already been evaluated.
            for (uint256 j; j < 2; ++j) {
                if (optimize) builder.check(OP_EQUAL, operands[i], operands[i]);
                else builder.instruction(OP_EQUAL, abi.encode(operands[i], operands[i]));
            }
            bindings[i] = ExecutingRecipe.binding(68 + 32 * i, operands[i]);
        }
        builder.call(address(this), abi.encodeCall(this.record, (new uint256[](operands.length))), bindings);
        return builder.finish();
    }

    function _arithmeticRecipe(bool optimize) internal view returns (ExecutingRecipe.Recipe memory) {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 value = _binary(builder, optimize, OP_ADD, builder.input(0), 0);
        value = _binary(builder, optimize, OP_ADD, value, 0);
        uint256 amount = _binary(builder, optimize, OP_ADD, 3, 4);
        uint256 total = _binary(builder, optimize, OP_ADD, value, amount);
        total = _binary(builder, optimize, OP_ADD, value, amount);
        total = optimize
            ? builder.mulDiv(total, 1, 1)
            : ExecutingRecipe.result(builder.instruction(OP_MUL_DIV, abi.encode(total, uint256(1), uint256(1))));
        for (uint256 i; i < 2; ++i) {
            if (optimize) builder.check(OP_LESS_OR_EQUAL, total, 100);
            else builder.instruction(OP_LESS_OR_EQUAL, abi.encode(total, uint256(100)));
        }
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = ExecutingRecipe.binding(4, total);
        builder.call(address(this), abi.encodeCall(this.set, (uint256(0))), bindings);
        return builder.finish();
    }

    function _binary(ExecutingRecipe.Builder memory builder, bool optimize, uint8 operation, uint256 a, uint256 b)
        internal
        pure
        returns (uint256)
    {
        return optimize
            ? builder.binary(operation, a, b)
            : ExecutingRecipe.result(builder.instruction(operation, abi.encode(a, b)));
    }

    function _run(ExecutingRecipe.Recipe memory recipe, uint256[] memory inputs) internal returns (uint256[] memory) {
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        return RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, inputs, new bytes[](0));
    }
}
