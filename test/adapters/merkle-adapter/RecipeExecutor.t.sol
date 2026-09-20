// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "../../../script/recipes/ExecutingRecipe.sol";

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {
    MerkleAdapterAssetReturnTarget,
    MerkleAdapterDelegatorMock,
    MerkleAdapterVaultMock
} from "../MerkleAdapter.t.sol";
import {ImmutableFactory} from "../../../src/contracts/common/ImmutableFactory.sol";
import {RecipeExecutor} from "../../../src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {MerkleAdapterVerifier} from "../../../src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "../../../src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

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
        executor = new RecipeExecutor(address(this), address(adapter));
        executor.setCaller(address(this));
        target = new RecipeTarget();
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
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(
            recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encodeCall(RecipeTarget.set, (99)))
        );
        assertEq(target.value(), 17);
    }

    function test_EmptyRecipeAndRuntimeLength() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(0);
        executor.setRecipe(recipe.queries, recipe.steps);
        assertEq(executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0)).length, 0);
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](1));
    }

    /// forge-config: default.isolate = true
    function test_ConfigurationFactoryAndCurrentCommitment() public {
        ImmutableFactory factory = new ImmutableFactory(type(RecipeExecutor).creationCode);
        address instance = factory.create(abi.encode(address(this), address(adapter)));
        assertTrue(factory.isEntity(instance));
        assertEq(RecipeExecutor(instance).adapter(), address(adapter));
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
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
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

    function test_OwnerAndCallerBoundaries() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(0);
        vm.startPrank(address(123));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(123)));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(123)));
        executor.setCaller(address(123));
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        vm.stopPrank();
        executor.setCaller(address(0));
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
    }

    function testFuzz_Arithmetic(uint128 x, uint128 y, uint128 divisor) public {
        divisor = uint128(bound(divisor, 1, type(uint128).max));
        ExecutingRecipe.Recipe memory recipe = _recipe(6);
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.Add, _input(0), _literal(y));
        recipe.steps[1] = _binary(IRecipeExecutor.Operation.Sub, _result(0), _literal(y));
        recipe.steps[2] = _binary(IRecipeExecutor.Operation.Min, _input(0), _literal(y));
        recipe.steps[3] = _mulDiv(_input(0), _literal(y), _literal(divisor));
        recipe.steps[4] = _binary(IRecipeExecutor.Operation.SaturatingSub, _input(0), _literal(y));
        recipe.steps[5] = _binary(IRecipeExecutor.Operation.Max, _input(0), _literal(y));
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
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.Min, _literal(a), _literal(b));
        recipe.steps[1] = _binary(IRecipeExecutor.Operation.Max, _literal(a), _literal(b));
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](2);
        bindings[0] = IRecipeExecutor.Binding({offset: 4, value: _result(1)});
        bindings[1] = IRecipeExecutor.Binding({offset: 36, value: _result(0)});
        recipe.steps[2] = _call(abi.encodeCall(RecipeTarget.setPair, (0, 0)), bindings);
        recipe.steps[3] = _binary(IRecipeExecutor.Operation.Sub, _result(1), _result(0));
        uint256[] memory values = _run(recipe, new uint256[](0), new bytes[](0));
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
            recipe.steps[0] = _binary(IRecipeExecutor.Operation.Min, _literal(a[i]), _literal(b[i]));
            recipe.steps[1] = _binary(IRecipeExecutor.Operation.Max, _literal(a[i]), _literal(b[i]));
            uint256[] memory values = _run(recipe, new uint256[](0), new bytes[](0));
            assertEq(values[0], a[i] < b[i] ? a[i] : b[i]);
            assertEq(values[1], a[i] > b[i] ? a[i] : b[i]);
        }
    }

    function test_FullWidthAndManyPriorResults() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(20);
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.Add, _literal(type(uint256).max), _literal(0));
        recipe.steps[1] = _binary(IRecipeExecutor.Operation.Sub, _result(0), _literal(type(uint256).max - 1));
        for (uint256 i = 2; i < 20; ++i) {
            recipe.steps[i] = _binary(IRecipeExecutor.Operation.Add, _result(i - 1), _result(1));
        }
        uint256[] memory values = _run(recipe, new uint256[](0), new bytes[](0));
        assertEq(values[0], type(uint256).max);
        assertEq(values[19], 19);
        recipe = _recipe(1);
        recipe.steps[0] = _mulDiv(_literal(type(uint256).max), _literal(type(uint256).max), _literal(type(uint256).max));
        assertEq(_run(recipe, new uint256[](0), new bytes[](0))[0], type(uint256).max);
    }

    function test_ArithmeticFailures() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.Add, _literal(type(uint256).max), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.Sub, _literal(0), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe.steps[0] = _mulDiv(_literal(0), _literal(1), _literal(0));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.divisionError);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
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
            vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        }
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.Add, _input(0), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe = _recipe(2);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (1)), _none());
        recipe.steps[1] = _binary(IRecipeExecutor.Operation.Add, _result(0), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(target.value(), 0);
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.Equal, _literal(0), _literal(0));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.Add, _literal(0), _literal(0));
        assertEq(_run(recipe, new uint256[](0), new bytes[](0))[1], 1);
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.Add, _result(1), _literal(0));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
    }

    function test_GlobalResultsUseInstructionIndicesAcrossCallsAndChecks() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(7);
        recipe.queries = new bytes[](1);
        recipe.queries[0] = _valueQuery();
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.Add, _literal(4), _literal(3));
        recipe.steps[1] = _binary(IRecipeExecutor.Operation.Equal, _result(0), _literal(7));
        recipe.steps[2] = _call(abi.encodeCall(RecipeTarget.set, (999)), _bindings(4, _result(0)));
        recipe.steps[3] = _read(0);
        recipe.steps[4] = _binary(IRecipeExecutor.Operation.Add, _result(3), _literal(5));
        recipe.steps[5] = _call(abi.encodeCall(RecipeTarget.set, (999)), _bindings(4, _result(4)));
        recipe.steps[6] = _read(0);
        uint256[] memory values = _run(recipe, new uint256[](0), new bytes[](0));
        assertEq(values.length, 7);
        assertEq(values[0], 7);
        assertEq(values[1], 0);
        assertEq(values[2], 0);
        assertEq(values[3], 7);
        assertEq(values[4], 12);
        assertEq(values[6], 12);
        assertEq(target.value(), 12);
    }

    function test_ChecksBeforePreventCallsAndChecksAfterRollback() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(2);
        for (uint256 comparison; comparison < 2; ++comparison) {
            IRecipeExecutor.Step memory check = _binary(
                comparison == 0 ? IRecipeExecutor.Operation.Equal : IRecipeExecutor.Operation.LessOrEqual,
                _literal(2),
                _literal(1)
            );
            recipe.steps[0] = check;
            recipe.steps[1] = _call(abi.encodeCall(RecipeTarget.set, (17)), _none());
            executor.setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
            assertEq(target.value(), 0);
            (recipe.steps[0], recipe.steps[1]) = (recipe.steps[1], recipe.steps[0]);
            executor.setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
            assertEq(target.value(), 0);
        }
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.LessOrEqual, _literal(1), _literal(2));
        recipe.steps[1] = _binary(IRecipeExecutor.Operation.LessOrEqual, _literal(2), _literal(2));
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
        recipe.steps[3] = _binary(IRecipeExecutor.Operation.Sub, _result(0), _result(2));
        assertEq(_run(recipe, new uint256[](0), new bytes[](0))[3], 13);
        recipe.steps[1] = _call(abi.encodeCall(RecipeTarget.set, (8)), _none());
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(target.value(), 7);
        recipe.steps[3] = _binary(IRecipeExecutor.Operation.Sub, _result(2), _result(0));
        assertEq(_run(recipe, new uint256[](0), new bytes[](0))[3], 1);
    }

    function test_ManageZeroGuardConsumesRuntimeButKeepsFollowingChecks() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(3);
        recipe.steps[0] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Manage,
            data: abi.encode(_literal(0), new bytes32[](0), new IRecipeExecutor.Binding[][](0))
        });
        recipe.steps[1] = _binary(IRecipeExecutor.Operation.Add, _literal(5), _literal(2));
        recipe.steps[2] = _binary(IRecipeExecutor.Operation.Equal, _result(1), _literal(7));
        assertEq(_run(recipe, new uint256[](0), _runtime(hex"ff"))[1], 7);
        vm.expectRevert(stdError.indexOOBError);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](2));
        recipe.steps[2] = _binary(IRecipeExecutor.Operation.Equal, _result(1), _literal(8));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(hex"ff"));
    }

    function test_RuntimeCountsAndSkippedResultReferencesRollBackEarlierCalls() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(3);
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (17)), _none());
        recipe.steps[1] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Manage,
            data: abi.encode(_literal(0), new bytes32[](0), new IRecipeExecutor.Binding[][](0))
        });
        recipe.steps[2] = _binary(IRecipeExecutor.Operation.Add, _literal(1), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(stdError.indexOOBError);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(target.value(), 0);
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](2));
        assertEq(target.value(), 0);
        recipe.steps[2] = _binary(IRecipeExecutor.Operation.Add, _result(1), _literal(1));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](1));
        assertEq(target.value(), 0);
    }

    /// forge-config: default.isolate = true
    function test_ReadMultipleBindingsWordSelectionAndStaticSafety() public {
        address queue = address(new RecipeParetoQueue(address(token)));
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](2);
        bindings[0] = IRecipeExecutor.Binding({offset: 4, value: _literal(uint256(uint160(address(adapter))))});
        bindings[1] = IRecipeExecutor.Binding({offset: 36, value: _literal(17)});
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
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](2);
        bindings[0] = IRecipeExecutor.Binding({offset: 4, value: _result(0)});
        bindings[1] = IRecipeExecutor.Binding({offset: 36, value: _result(1)});
        ExecutingRecipe.Recipe memory recipe = _recipe(3);
        recipe.steps[0] = _binary(IRecipeExecutor.Operation.Add, _input(0), _literal(3));
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
            [uint256(0), 1, 3, 37, 68, 69, type(uint256).max - 32, type(uint256).max - 31, type(uint256).max];
        for (uint256 i; i < offsets.length; ++i) {
            recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.setPair, (0, 0)), _bindings(offsets[i], _literal(1)));
            executor.setRecipe(recipe.queries, recipe.steps);
            if (offsets[i] > type(uint256).max - 32) vm.expectRevert(stdError.arithmeticError);
            else vm.expectRevert(IRecipeExecutor.InvalidCall.selector);
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        }
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](2);
        bindings[0] = IRecipeExecutor.Binding({offset: 36, value: _literal(1)});
        bindings[1] = IRecipeExecutor.Binding({offset: 4, value: _literal(2)});
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.setPair, (0, 0)), bindings);
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidCall.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        bindings[0].offset = 4;
        bindings[1].offset = 35;
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.setPair, (0, 0)), bindings);
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidCall.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe.steps[0] = _call(abi.encodeCall(RecipeTarget.set, (0)), _bindings(4, _result(0)));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
    }

    function test_CommittedCallAllowsEmptyAndShortFallbackData() public {
        RecipeFallbackTarget fallbackTarget = new RecipeFallbackTarget();
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        for (uint256 i; i <= 4; ++i) {
            recipe.steps[0] = IRecipeExecutor.Step({
                operation: IRecipeExecutor.Operation.Call,
                data: abi.encode(address(fallbackTarget), Bytes.slice(hex"12345678", 0, i), _none())
            });
            _run(recipe, new uint256[](0), new bytes[](0));
            assertEq(fallbackTarget.calls(), i + 1);
        }
    }

    /// forge-config: default.isolate = true
    function test_ManageUsesAdapterAndCurrentPermissions() public {
        IMerkleAdapter.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _manageRecipe(action);
        _run(recipe, new uint256[](0), _runtime(data));
        vm.snapshotGasLastCall("RecipeExecutor", "executeManage");
        assertEq(target.value(), 7);
        assertEq(target.sender(), account);
        adapter.revokeRole(_leaf(action), address(executor));
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(data));
        adapter.grantRole(_leaf(action), address(executor));
        roots.setRoot(address(adapter), bytes32(uint256(123)));
        adapter.acceptRoot(bytes32(uint256(123)));
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(data));
    }

    function test_ManageDecodesRelocatedDataAndRequiresExactCount() public {
        IMerkleAdapter.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (ExecutingRecipe.Recipe memory recipe, bytes memory canonical) = _manageRecipe(action);
        executor.setRecipe(recipe.queries, recipe.steps);
        bytes memory relocated = bytes.concat(canonical, Bytes.slice(abi.encode(action.data), 32));
        Bytes.replace(relocated, 160, abi.encode(canonical.length - 96));
        assertEq(abi.encode(abi.decode(relocated, (IMerkleAdapter.Action[]))), canonical);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(relocated));
        assertEq(target.value(), 7);
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(
            recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(new IMerkleAdapter.Action[](0)))
        );
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        recipe.steps[0].data = abi.encode(_literal(1), leaves, new IRecipeExecutor.Binding[][](0));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(canonical));
    }

    function test_ManageVerifiesFinalBoundLeafAndRejectsNativeValue() public {
        IMerkleAdapter.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (ExecutingRecipe.Recipe memory recipe,) = _manageRecipe(action);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        IRecipeExecutor.Binding[][] memory bindings = new IRecipeExecutor.Binding[][](1);
        bindings[0] = _bindings(4, _literal(7));
        recipe.steps[0].data = abi.encode(_literal(1), leaves, bindings);
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        action.data = abi.encodeCall(RecipeTarget.set, (0));
        actions[0] = action;
        _run(recipe, new uint256[](0), _runtime(abi.encode(actions)));
        assertEq(target.value(), 7);
        bindings[0][0].value = _literal(8);
        recipe.steps[0].data = abi.encode(_literal(1), leaves, bindings);
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(actions)));
        bindings[0][0].value = _literal(7);
        recipe.steps[0].data = abi.encode(_literal(1), leaves, bindings);
        actions[0].value = 1;
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(actions)));
    }

    function test_ManageBindsMultipleActionsAndPreservesOrder() public {
        address second = address(new RecipeTarget());
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(target), abi.encodeCall(RecipeTarget.setPair, (0, 0)));
        actions[1] = _action(second, abi.encodeCall(RecipeTarget.setPair, (0, 0)));
        for (uint256 i; i < 2; ++i) {
            for (uint256 j = 4; j < 68; ++j) {
                actions[i].dataMask[j] = 0xff;
            }
        }
        bytes32[] memory leaves = _publishPair(actions);
        IRecipeExecutor.Binding[][] memory bindings = new IRecipeExecutor.Binding[][](2);
        for (uint256 i; i < 2; ++i) {
            bindings[i] = new IRecipeExecutor.Binding[](2);
            bindings[i][0] = IRecipeExecutor.Binding({offset: 4, value: _input(i)});
            bindings[i][1] = IRecipeExecutor.Binding({offset: 36, value: _literal(type(uint256).max)});
        }
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Manage, data: abi.encode(_literal(1), leaves, bindings)
        });
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = 7;
        inputs[1] = 9;
        _run(recipe, inputs, _runtime(abi.encode(actions)));
        assertEq(target.value(), 7);
        assertEq(RecipeTarget(second).value(), 9);
        assertEq(target.other(), type(uint256).max);
        assertEq(target.sender(), account);
        (actions[0], actions[1]) = (actions[1], actions[0]);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(recipe.queries, recipe.steps, inputs, _runtime(abi.encode(actions)));
        assertEq(target.value(), 7);
    }

    function test_ManageRejectsAnotherAuthorizedLeaf() public {
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        actions[1] = _action(address(target), abi.encodeCall(RecipeTarget.set, (9)));
        bytes32[] memory leaves = _publishPair(actions);
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        bytes32[] memory selected = new bytes32[](1);
        selected[0] = leaves[0];
        recipe.steps[0] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Manage,
            data: abi.encode(_literal(1), selected, new IRecipeExecutor.Binding[][](1))
        });
        executor.setRecipe(recipe.queries, recipe.steps);
        IMerkleAdapter.Action[] memory supplied = new IMerkleAdapter.Action[](1);
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
        assertEq(adapter.reservedAssets(), 50);
        address recipient = address(new MerkleAdapterAssetReturnTarget());
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(adapter), abi.encodeCall(IMerkleAdapter.release, (1)));
        actions[1] = _action(
            recipient,
            abi.encodeCall(MerkleAdapterAssetReturnTarget.returnAsset, (IERC20(address(token)), address(adapter), 1))
        );
        bytes32[] memory leaves = _publishPair(actions);
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Manage,
            data: abi.encode(_literal(1), leaves, new IRecipeExecutor.Binding[][](2))
        });
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
            recipe.steps[i] = IRecipeExecutor.Step({
                operation: IRecipeExecutor.Operation.Manage,
                data: abi.encode(_literal(1), single, new IRecipeExecutor.Binding[][](1))
            });
            IMerkleAdapter.Action[] memory supplied = new IMerkleAdapter.Action[](1);
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
        IMerkleAdapter.Action memory action = _action(
            address(target), abi.encodeCall(RecipeTarget.setEncoded, (abi.encodeCall(RecipeTarget.setPair, (0, 0))))
        );
        for (uint256 i = 72; i < 136; ++i) {
            action.dataMask[i] = 0xff;
        }
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _manageRecipe(action);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        IRecipeExecutor.Binding[][] memory bindings = new IRecipeExecutor.Binding[][](1);
        bindings[0] = new IRecipeExecutor.Binding[](2);
        bindings[0][0] = IRecipeExecutor.Binding({offset: 72, value: _literal(23)});
        bindings[0][1] = IRecipeExecutor.Binding({offset: 104, value: _literal(45)});
        recipe.steps[0].data = abi.encode(_literal(1), leaves, bindings);
        _run(recipe, new uint256[](0), _runtime(data));
        assertEq(target.value(), 23);
        assertEq(target.other(), 45);
        bindings[0] = _bindings(4, _literal(64));
        recipe.steps[0].data = abi.encode(_literal(1), leaves, bindings);
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

    function test_ApprovalNoReturnFalseMalformedAndTrailingReturn() public {
        (ExecutingRecipe.Recipe memory recipe, bytes memory data) = _approvalRecipe(100);
        token.setMode(1);
        _run(recipe, new uint256[](0), _runtime(data));
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
        IRecipeExecutor.Step memory approval = recipe.steps[0];
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
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(token), abi.encodeCall(IERC20.approve, (address(target), uint256(0))));
        actions[0].dataMask = dataMask;
        actions[1] = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        _publishPair(actions);
        _run(recipe, new uint256[](0), _runtime(abi.encode(dataMask, actions[0].proof)));
        assertEq(token.allowance(account, address(target)), 100);
        assertEq(token.lastApprover(), account);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(data));
        assertEq(token.allowance(account, address(target)), 100);
    }

    /// forge-config: default.isolate = true
    function test_ParetoCapturedEpochReceiptAndRollback() public {
        address queue = address(new RecipeParetoQueue(address(token)));
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
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
        recipe.steps[1] = _binary(IRecipeExecutor.Operation.Add, _result(0), _literal(1));
        recipe.steps[2] = _read(1);
        recipe.steps[3] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Manage,
            data: abi.encode(_literal(1), leaves, new IRecipeExecutor.Binding[][](2))
        });
        recipe.steps[4] = _read(1);
        recipe.steps[5] = _binary(IRecipeExecutor.Operation.Sub, _result(4), _result(2));
        recipe.steps[6] = _binary(IRecipeExecutor.Operation.Equal, _result(5), _literal(1 ether));
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
            vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), _runtime(abi.encode(actions)));
            assertEq(token.balanceOf(account), 1 ether);
            assertEq(token.allowance(account, queue), 0);
            assertEq(RecipeParetoQueue(queue).userWithdrawalsEpochs(account, 10), 2 ether);
        }
    }

    function _recipe(uint256 length) internal pure returns (ExecutingRecipe.Recipe memory recipe) {
        recipe.queries = new bytes[](0);
        recipe.steps = new IRecipeExecutor.Step[](length);
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

    function _literal(uint256 value) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value({source: IRecipeExecutor.Source.Literal, value: value});
    }

    function _input(uint256 index) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value({source: IRecipeExecutor.Source.Input, value: index});
    }

    function _result(uint256 index) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value({source: IRecipeExecutor.Source.Result, value: index});
    }

    function _binary(
        IRecipeExecutor.Operation operation,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b
    ) internal pure returns (IRecipeExecutor.Step memory) {
        return IRecipeExecutor.Step({operation: operation, data: abi.encode(a, b)});
    }

    function _mulDiv(IRecipeExecutor.Value memory a, IRecipeExecutor.Value memory b, IRecipeExecutor.Value memory c)
        internal
        pure
        returns (IRecipeExecutor.Step memory)
    {
        return IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.MulDiv, data: abi.encode(a, b, c)});
    }

    function _read(uint256 index) internal pure returns (IRecipeExecutor.Step memory) {
        return IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.Read, data: abi.encode(index)});
    }

    function _query(address recipient, bytes memory data, IRecipeExecutor.Binding[] memory bindings, uint256 offset)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(recipient, data, bindings, offset);
    }

    function _valueQuery() internal view returns (bytes memory) {
        return _query(address(target), abi.encodeWithSignature("value()"), _none(), 0);
    }

    function _none() internal pure returns (IRecipeExecutor.Binding[] memory) {
        return new IRecipeExecutor.Binding[](0);
    }

    function _bindings(uint256 offset, IRecipeExecutor.Value memory value)
        internal
        pure
        returns (IRecipeExecutor.Binding[] memory bindings)
    {
        bindings = new IRecipeExecutor.Binding[](1);
        bindings[0] = IRecipeExecutor.Binding({offset: offset, value: value});
    }

    function _call(bytes memory data, IRecipeExecutor.Binding[] memory bindings)
        internal
        view
        returns (IRecipeExecutor.Step memory)
    {
        return IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Call, data: abi.encode(address(target), data, bindings)
        });
    }

    function _action(address recipient, bytes memory data) internal pure returns (IMerkleAdapter.Action memory) {
        return IMerkleAdapter.Action({
            target: recipient, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
    }

    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        return MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
    }

    function _publish(IMerkleAdapter.Action memory action) internal {
        bytes32 leaf = _leaf(action);
        roots.setRoot(address(adapter), leaf);
        adapter.acceptRoot(leaf);
        adapter.grantRole(leaf, address(executor));
    }

    function _manageRecipe(IMerkleAdapter.Action memory action)
        internal
        returns (ExecutingRecipe.Recipe memory recipe, bytes memory data)
    {
        _publish(action);
        recipe = _recipe(1);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        recipe.steps[0] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Manage,
            data: abi.encode(_literal(1), leaves, new IRecipeExecutor.Binding[][](1))
        });
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        actions[0] = action;
        data = abi.encode(actions);
    }

    function _approvalRecipe(uint256 amount)
        internal
        returns (ExecutingRecipe.Recipe memory recipe, bytes memory data)
    {
        IMerkleAdapter.Action memory action = _action(
            address(token), abi.encodeCall(IERC20.approve, (address(target), uint256(0)))
        );
        for (uint256 i = 36; i < 68; ++i) {
            action.dataMask[i] = 0xff;
        }
        _publish(action);
        recipe = _recipe(1);
        recipe.steps[0] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Approve,
            data: abi.encode(_literal(amount), address(token), address(target), _leaf(action))
        });
        data = abi.encode(action.dataMask, action.proof);
    }

    function _approvalAmount(ExecutingRecipe.Recipe memory recipe, uint256 amount) internal pure {
        (, address asset, address spender, bytes32 leaf) =
            abi.decode(recipe.steps[0].data, (IRecipeExecutor.Value, address, address, bytes32));
        recipe.steps[0].data = abi.encode(_literal(amount), asset, spender, leaf);
    }

    function _publishPair(IMerkleAdapter.Action[] memory actions) internal returns (bytes32[] memory leaves) {
        leaves = new bytes32[](2);
        for (uint256 i; i < 2; ++i) {
            leaves[i] = _leaf(actions[i]);
        }
        bytes32 root = leaves[0] < leaves[1]
            ? keccak256(abi.encodePacked(leaves[0], leaves[1]))
            : keccak256(abi.encodePacked(leaves[1], leaves[0]));
        roots.setRoot(address(adapter), root);
        adapter.acceptRoot(root);
        for (uint256 i; i < 2; ++i) {
            actions[i].proof = new bytes32[](1);
            actions[i].proof[0] = leaves[1 - i];
            adapter.grantRole(leaves[i], address(executor));
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
