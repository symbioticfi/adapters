// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
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
    function test_ActionWithoutExpressionsProducesNoResults() public {
        IRecipeExecutor.Step memory step = _invoke(RecipeTarget.set.selector, _none());
        uint256[] memory values = _run(step, new uint256[](0), abi.encodeCall(RecipeTarget.set, (17)));
        vm.snapshotGasLastCall("RecipeExecutor", "executeInvoke");
        assertEq(target.value(), 17);
        assertEq(values.length, 0);
    }

    function test_EmptyRecipeAndRuntimeLength() public {
        assertEq(executor.execute(new uint256[](0), new bytes[](0)).length, 0);
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(new uint256[](0), new bytes[](1));
    }

    /// forge-config: default.isolate = true
    function test_ConfigurationFactoryAndCurrentRecipe() public {
        ImmutableFactory factory = new ImmutableFactory(type(RecipeExecutor).creationCode);
        address instance = factory.create(abi.encode(address(this), address(adapter)));
        assertTrue(factory.isEntity(instance));
        assertEq(RecipeExecutor(instance).adapter(), address(adapter));
        assertEq(RecipeExecutor(instance).owner(), address(this));
        assertEq(RecipeExecutor(instance).caller(), address(0));
        executor.setCaller(address(this));
        vm.snapshotGasLastCall("RecipeExecutor", "setCaller");
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = _invoke(RecipeTarget.set.selector, _bindings(4, _literal(10)));
        executor.setRecipe(recipe);
        vm.snapshotGasLastCall("RecipeExecutor", "setRecipe");
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encodeCall(RecipeTarget.set, (999));
        recipe[0].data = abi.encode(address(target), RecipeTarget.set.selector, _bindings(4, _literal(11)));
        executor.execute(new uint256[](0), runtime);
        assertEq(target.value(), 10);
        executor.setRecipe(recipe);
        executor.execute(new uint256[](0), runtime);
        assertEq(target.value(), 11);
        executor.setRecipe(new IRecipeExecutor.Step[](0));
        vm.snapshotGasLastCall("RecipeExecutor", "setRecipeClear");
        assertEq(executor.execute(new uint256[](0), new bytes[](0)).length, 0);
        vm.snapshotGasLastCall("RecipeExecutor", "executeEmpty");
        vm.expectRevert();
        executor.steps(0);
    }

    function test_OwnerAndCallerBoundaries() public {
        vm.startPrank(address(123));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(123)));
        executor.setRecipe(new IRecipeExecutor.Step[](0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(123)));
        executor.setCaller(address(123));
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.execute(new uint256[](0), new bytes[](0));
        vm.stopPrank();
        executor.setCaller(address(0));
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.execute(new uint256[](0), new bytes[](0));
    }

    function testFuzz_InlineArithmetic(uint128 x, uint128 y, uint128 divisor) public {
        divisor = uint128(bound(divisor, 1, type(uint128).max));
        IRecipeExecutor.Step memory step;
        step.beforeExpressions = new IRecipeExecutor.Expression[](5);
        step.beforeExpressions[0] = _expression(IRecipeExecutor.Operation.Add, _input(0), _literal(y), _literal(0));
        step.beforeExpressions[1] =
            _expression(IRecipeExecutor.Operation.Subtract, _result(0), _literal(y), _literal(0));
        step.beforeExpressions[2] = _expression(IRecipeExecutor.Operation.Minimum, _input(0), _literal(y), _literal(0));
        step.beforeExpressions[3] =
            _expression(IRecipeExecutor.Operation.MulDiv, _input(0), _literal(y), _literal(divisor));
        step.beforeExpressions[4] =
            _expression(IRecipeExecutor.Operation.SaturatingSubtract, _input(0), _literal(y), _literal(0));
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = x;
        uint256[] memory values = _run(step, inputs, "");
        assertEq(values[0], uint256(x) + y);
        assertEq(values[1], x);
        assertEq(values[2], x < y ? x : y);
        assertEq(values[3], uint256(x) * y / divisor);
        assertEq(values[4], x > y ? x - y : 0);
    }

    function test_FullWidthAndManyPriorResults() public {
        IRecipeExecutor.Step memory step;
        step.beforeExpressions = new IRecipeExecutor.Expression[](20);
        step.beforeExpressions[0] =
            _expression(IRecipeExecutor.Operation.Add, _literal(type(uint256).max), _literal(0), _literal(0));
        step.beforeExpressions[1] =
            _expression(IRecipeExecutor.Operation.Subtract, _result(0), _literal(type(uint256).max - 1), _literal(0));
        for (uint256 i = 2; i < 20; ++i) {
            step.beforeExpressions[i] =
                _expression(IRecipeExecutor.Operation.Add, _result(i - 1), _result(1), _literal(0));
        }
        uint256[] memory values = _run(step, new uint256[](0), "");
        assertEq(values[0], type(uint256).max);
        assertEq(values[19], 19);
    }

    function test_ArithmeticFailures() public {
        IRecipeExecutor.Step memory step;
        step.beforeExpressions = new IRecipeExecutor.Expression[](1);
        step.beforeExpressions[0] =
            _expression(IRecipeExecutor.Operation.Add, _literal(type(uint256).max), _literal(1), _literal(0));
        _save(step);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(new uint256[](0), new bytes[](1));
        step.beforeExpressions[0] =
            _expression(IRecipeExecutor.Operation.Subtract, _literal(0), _literal(1), _literal(0));
        _save(step);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(new uint256[](0), new bytes[](1));
        step.beforeExpressions[0] = _expression(IRecipeExecutor.Operation.MulDiv, _literal(0), _literal(1), _literal(0));
        _save(step);
        vm.expectRevert(stdError.divisionError);
        executor.execute(new uint256[](0), new bytes[](1));
    }

    function test_ReferencesRequirePopulatedResultsAndExistingInputs() public {
        IRecipeExecutor.Step memory step;
        step.beforeExpressions = new IRecipeExecutor.Expression[](1);
        for (uint256 operand; operand < 3; ++operand) {
            step.beforeExpressions[0] =
                _expression(IRecipeExecutor.Operation.MulDiv, _literal(1), _literal(1), _literal(1));
            if (operand == 0) step.beforeExpressions[0].a = _result(0);
            else if (operand == 1) step.beforeExpressions[0].b = _result(0);
            else step.beforeExpressions[0].c = _result(0);
            _save(step);
            vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
            executor.execute(new uint256[](0), new bytes[](1));
        }
        step.beforeExpressions[0].c = _input(0);
        _save(step);
        vm.expectRevert(stdError.indexOOBError);
        executor.execute(new uint256[](0), new bytes[](1));
    }

    function test_GlobalResultsFlowThroughBeforeObservationsAfterAndNextAction() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](2);
        recipe[0] = _invoke(RecipeTarget.set.selector, _bindings(4, _result(0)));
        recipe[0].beforeExpressions = new IRecipeExecutor.Expression[](1);
        recipe[0].beforeExpressions[0] =
            _expression(IRecipeExecutor.Operation.Add, _literal(4), _literal(3), _literal(0));
        recipe[0].checksBefore = _checks(_result(0), _literal(7), IRecipeExecutor.Comparison.Equal);
        recipe[0].observations = _observations(_valueQuery(), IRecipeExecutor.ObservationKind.Increase);
        recipe[0].afterExpressions = new IRecipeExecutor.Expression[](1);
        recipe[0].afterExpressions[0] = _expression(IRecipeExecutor.Operation.Add, _result(1), _literal(5), _literal(0));
        recipe[0].checksAfter = _checks(_result(2), _literal(12), IRecipeExecutor.Comparison.Equal);
        recipe[1] = _invoke(RecipeTarget.set.selector, _bindings(4, _result(2)));
        recipe[1].observations = _observations(_valueQuery(), IRecipeExecutor.ObservationKind.After);
        recipe[1].checksAfter = _checks(_result(3), _result(2), IRecipeExecutor.Comparison.Equal);
        bytes[] memory runtime = new bytes[](2);
        runtime[0] = abi.encodeCall(RecipeTarget.set, (999));
        runtime[1] = runtime[0];
        executor.setRecipe(recipe);
        uint256[] memory values = executor.execute(new uint256[](0), runtime);
        assertEq(values.length, 4);
        assertEq(values[0], 7);
        assertEq(values[1], 7);
        assertEq(values[2], 12);
        assertEq(values[3], 12);
        assertEq(target.value(), 12);
    }

    function test_ChecksBeforePreventCallsAndChecksAfterRollback() public {
        IRecipeExecutor.Step memory step = _invoke(RecipeTarget.set.selector, _none());
        for (uint256 comparison; comparison < 3; ++comparison) {
            step.checksBefore =
                _checks(_literal(comparison == 1 ? 0 : 2), _literal(1), IRecipeExecutor.Comparison(comparison));
            _save(step);
            bytes[] memory runtime = _runtime(abi.encodeCall(RecipeTarget.set, (17)));
            vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
            executor.execute(new uint256[](0), runtime);
            assertEq(target.value(), 0);
            step.checksBefore = new IRecipeExecutor.Check[](0);
            step.observations = _observations(_valueQuery(), IRecipeExecutor.ObservationKind.After);
            step.checksAfter =
                _checks(_result(0), _literal(comparison == 1 ? 18 : 16), IRecipeExecutor.Comparison(comparison));
            _save(step);
            vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
            executor.execute(new uint256[](0), runtime);
            assertEq(target.value(), 0);
            step.checksAfter = new IRecipeExecutor.Check[](0);
        }
    }

    function test_ObservationDirectionsAndFrozenQueries() public {
        target.set(20);
        IRecipeExecutor.Step memory step = _invoke(RecipeTarget.set.selector, _none());
        step.observations = _observations(_valueQuery(), IRecipeExecutor.ObservationKind.Decrease);
        assertEq(_run(step, new uint256[](0), abi.encodeCall(RecipeTarget.set, (7)))[0], 13);
        _save(step);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(new uint256[](0), _runtime(abi.encodeCall(RecipeTarget.set, (8))));
        assertEq(target.value(), 7);
        step.observations[0].kind = IRecipeExecutor.ObservationKind.Increase;
        _save(step);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(new uint256[](0), _runtime(abi.encodeCall(RecipeTarget.set, (6))));
        assertEq(target.value(), 7);

        step.observations = new IRecipeExecutor.Observation[](2);
        step.observations[0] = IRecipeExecutor.Observation(_valueQuery(), IRecipeExecutor.ObservationKind.After);
        step.observations[1] = IRecipeExecutor.Observation(
            _query(address(target), abi.encodeCall(RecipeTarget.echo, (0)), _bindings(4, _result(0)), 0),
            IRecipeExecutor.ObservationKind.After
        );
        _save(step);
        vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
        executor.execute(new uint256[](0), _runtime(abi.encodeCall(RecipeTarget.set, (17))));
        assertEq(target.value(), 7);
    }

    function test_ManageZeroGuardStillRunsObservationsAndConditions() public {
        IRecipeExecutor.Step memory step;
        step.data = hex"ff";
        step.beforeExpressions = new IRecipeExecutor.Expression[](1);
        step.beforeExpressions[0] = _expression(IRecipeExecutor.Operation.Add, _literal(5), _literal(2), _literal(0));
        step.observations = _observations(_valueQuery(), IRecipeExecutor.ObservationKind.Increase);
        step.afterExpressions = new IRecipeExecutor.Expression[](1);
        step.afterExpressions[0] = _expression(IRecipeExecutor.Operation.Add, _result(0), _result(1), _literal(0));
        step.checksAfter = _checks(_result(2), _literal(7), IRecipeExecutor.Comparison.Equal);
        uint256[] memory values = _run(step, new uint256[](0), hex"ff");
        assertEq(values.length, 3);
        assertEq(values[1], 0);
        step.checksAfter[0].b = _literal(8);
        _save(step);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        executor.execute(new uint256[](0), _runtime(hex"ff"));
    }

    /// forge-config: default.isolate = true
    function test_ReadMultipleBindingsWordSelectionAndStaticSafety() public {
        address queue = address(new RecipeParetoQueue(address(token)));
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](2);
        bindings[0] = IRecipeExecutor.Binding(4, _literal(uint256(uint160(address(adapter)))));
        bindings[1] = IRecipeExecutor.Binding(36, _literal(17));
        IRecipeExecutor.Step memory step;
        step.beforeExpressions = new IRecipeExecutor.Expression[](1);
        step.beforeExpressions[0] =
            _read(_query(queue, abi.encodeCall(RecipeParetoQueue.query, (address(0), uint256(0))), bindings, 0));
        assertEq(_run(step, new uint256[](0), "")[0], uint256(keccak256(abi.encode(address(adapter), uint256(17)))));
        step.beforeExpressions[0] = _read(_query(address(target), abi.encodeCall(RecipeTarget.pair, ()), _none(), 32));
        assertEq(_run(step, new uint256[](0), "")[0], 42);
        vm.snapshotGasLastCall("RecipeExecutor", "executeRead");
        step.beforeExpressions[0] = _read(_query(address(target), abi.encodeCall(RecipeTarget.pair, ()), _none(), 33));
        _save(step);
        vm.expectRevert();
        executor.execute(new uint256[](0), new bytes[](1));
        step.beforeExpressions[0] = _read(_query(address(target), abi.encodeCall(RecipeTarget.set, (17)), _none(), 0));
        _save(step);
        vm.expectRevert();
        executor.execute{gas: 500_000}(new uint256[](0), new bytes[](1));
        assertEq(target.value(), 0);
    }

    function testFuzz_InvokeBindsMultipleCalculatedValues(uint128 first, uint128 second) public {
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](2);
        bindings[0] = IRecipeExecutor.Binding(4, _result(0));
        bindings[1] = IRecipeExecutor.Binding(36, _result(1));
        IRecipeExecutor.Step memory step = _invoke(RecipeTarget.setPair.selector, bindings);
        step.beforeExpressions = new IRecipeExecutor.Expression[](2);
        step.beforeExpressions[0] = _expression(IRecipeExecutor.Operation.Add, _input(0), _literal(3), _literal(0));
        step.beforeExpressions[1] = _expression(IRecipeExecutor.Operation.MulDiv, _input(1), _literal(2), _literal(1));
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = first;
        inputs[1] = second;
        _run(step, inputs, abi.encodeCall(RecipeTarget.setPair, (111, 222)));
        assertEq(target.value(), uint256(first) + 3);
        assertEq(target.other(), uint256(second) * 2);
        assertEq(target.sender(), address(executor));
        assertEq(executor.steps(0), abi.encode(step));
    }

    function test_BindingBoundsOrderingAndReferences() public {
        IRecipeExecutor.Step memory step = _invoke(RecipeTarget.setPair.selector, _none());
        uint256[7] memory offsets = [uint256(0), 1, 3, 37, 68, 69, type(uint256).max];
        for (uint256 i; i < offsets.length; ++i) {
            step.data = abi.encode(address(target), RecipeTarget.setPair.selector, _bindings(offsets[i], _literal(1)));
            _save(step);
            vm.expectRevert(IRecipeExecutor.InvalidCall.selector);
            executor.execute(new uint256[](0), _runtime(abi.encodeCall(RecipeTarget.setPair, (0, 0))));
        }
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](2);
        bindings[0] = IRecipeExecutor.Binding(36, _literal(1));
        bindings[1] = IRecipeExecutor.Binding(4, _literal(2));
        step.data = abi.encode(address(target), RecipeTarget.setPair.selector, bindings);
        _save(step);
        vm.expectRevert(IRecipeExecutor.InvalidCall.selector);
        executor.execute(new uint256[](0), _runtime(abi.encodeCall(RecipeTarget.setPair, (0, 0))));
        bindings[0].offset = 4;
        bindings[1].offset = 35;
        step.data = abi.encode(address(target), RecipeTarget.setPair.selector, bindings);
        _save(step);
        vm.expectRevert(IRecipeExecutor.InvalidCall.selector);
        executor.execute(new uint256[](0), _runtime(abi.encodeCall(RecipeTarget.setPair, (0, 0))));
        step.data = abi.encode(address(target), RecipeTarget.setPair.selector, _bindings(4, _result(0)));
        _save(step);
        vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
        executor.execute(new uint256[](0), _runtime(abi.encodeCall(RecipeTarget.setPair, (0, 0))));
        vm.expectRevert(IRecipeExecutor.InvalidCall.selector);
        executor.execute(new uint256[](0), _runtime(abi.encodeCall(RecipeTarget.set, (0))));
        vm.expectRevert(IRecipeExecutor.InvalidCall.selector);
        executor.execute(new uint256[](0), _runtime(hex"1234"));
    }

    /// forge-config: default.isolate = true
    function test_ManageUsesAdapterAndCurrentPermissions() public {
        IMerkleAdapter.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (IRecipeExecutor.Step memory step, bytes memory data) = _manageRecipe(action);
        _run(step, new uint256[](0), data);
        vm.snapshotGasLastCall("RecipeExecutor", "executeManage");
        assertEq(target.value(), 7);
        assertEq(target.sender(), address(adapter));
        adapter.revokeRole(_leaf(action), address(executor));
        vm.expectRevert();
        executor.execute(new uint256[](0), _runtime(data));
        adapter.grantRole(_leaf(action), address(executor));
        roots.setRoot(address(adapter), bytes32(uint256(123)));
        adapter.acceptRoot(bytes32(uint256(123)));
        vm.expectRevert();
        executor.execute(new uint256[](0), _runtime(data));
    }

    function test_ManageRequiresCanonicalEncodingAndExactCount() public {
        IMerkleAdapter.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (IRecipeExecutor.Step memory step, bytes memory canonical) = _manageRecipe(action);
        _save(step);
        bytes memory relocated = bytes.concat(canonical, Bytes.slice(abi.encode(action.data), 32));
        Bytes.replace(relocated, 160, abi.encode(canonical.length - 96));
        assertEq(abi.encode(abi.decode(relocated, (IMerkleAdapter.Action[]))), canonical);
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(new uint256[](0), _runtime(relocated));
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(new uint256[](0), _runtime(abi.encode(new IMerkleAdapter.Action[](0))));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        step.data = abi.encode(leaves, new IRecipeExecutor.Binding[][](0));
        _save(step);
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(new uint256[](0), _runtime(canonical));
    }

    function test_ManageVerifiesFinalBoundLeafAndRejectsNativeValue() public {
        IMerkleAdapter.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (IRecipeExecutor.Step memory step,) = _manageRecipe(action);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        IRecipeExecutor.Binding[][] memory bindings = new IRecipeExecutor.Binding[][](1);
        bindings[0] = _bindings(4, _literal(7));
        step.data = abi.encode(leaves, bindings);
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        action.data = abi.encodeCall(RecipeTarget.set, (0));
        actions[0] = action;
        _run(step, new uint256[](0), abi.encode(actions));
        assertEq(target.value(), 7);
        bindings[0][0].value = _literal(8);
        step.data = abi.encode(leaves, bindings);
        _save(step);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(new uint256[](0), _runtime(abi.encode(actions)));
        bindings[0][0].value = _literal(7);
        step.data = abi.encode(leaves, bindings);
        actions[0].value = 1;
        _save(step);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(new uint256[](0), _runtime(abi.encode(actions)));
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
            bindings[i][0] = IRecipeExecutor.Binding(4, _input(i));
            bindings[i][1] = IRecipeExecutor.Binding(36, _literal(type(uint256).max));
        }
        IRecipeExecutor.Step memory step;
        step.kind = IRecipeExecutor.Kind.Manage;
        step.amount = _literal(1);
        step.data = abi.encode(leaves, bindings);
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = 7;
        inputs[1] = 9;
        _run(step, inputs, abi.encode(actions));
        assertEq(target.value(), 7);
        assertEq(RecipeTarget(second).value(), 9);
        assertEq(target.other(), type(uint256).max);
        assertEq(target.sender(), address(adapter));
        (actions[0], actions[1]) = (actions[1], actions[0]);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(inputs, _runtime(abi.encode(actions)));
        assertEq(target.value(), 7);
    }

    function test_ManageNestedUnalignedWordsPreserveAbiHeaders() public {
        IMerkleAdapter.Action memory action = _action(
            address(target), abi.encodeCall(RecipeTarget.setEncoded, (abi.encodeCall(RecipeTarget.setPair, (0, 0))))
        );
        for (uint256 i = 72; i < 136; ++i) {
            action.dataMask[i] = 0xff;
        }
        (IRecipeExecutor.Step memory step, bytes memory data) = _manageRecipe(action);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        IRecipeExecutor.Binding[][] memory bindings = new IRecipeExecutor.Binding[][](1);
        bindings[0] = new IRecipeExecutor.Binding[](2);
        bindings[0][0] = IRecipeExecutor.Binding(72, _literal(23));
        bindings[0][1] = IRecipeExecutor.Binding(104, _literal(45));
        step.data = abi.encode(leaves, bindings);
        _run(step, new uint256[](0), data);
        assertEq(target.value(), 23);
        assertEq(target.other(), 45);
        bindings[0] = _bindings(4, _literal(64));
        step.data = abi.encode(leaves, bindings);
        _save(step);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(new uint256[](0), _runtime(data));
    }

    /// forge-config: default.isolate = true
    function test_ApproveResetsClearsAndRunsFromAdapter() public {
        uint256 initialCalls = token.calls();
        (IRecipeExecutor.Step memory step, bytes memory data) = _approvalRecipe(100);
        _run(step, new uint256[](0), data);
        vm.snapshotGasLastCall("RecipeExecutor", "executeApprove");
        assertEq(token.allowance(address(adapter), address(target)), 100);
        assertEq(token.lastApprover(), address(adapter));
        step.amount = _literal(200);
        _run(step, new uint256[](0), data);
        vm.snapshotGasLastCall("RecipeExecutor", "executeApproveReset");
        assertEq(token.calls(), initialCalls + 3);
        assertEq(token.allowance(address(adapter), address(target)), 200);
        step.amount = _literal(0);
        _run(step, new uint256[](0), data);
        vm.snapshotGasLastCall("RecipeExecutor", "executeApproveClear");
        assertEq(token.calls(), initialCalls + 4);
        assertEq(token.allowance(address(adapter), address(target)), 0);
    }

    function test_ApprovalNoReturnFalseAndMalformedReturn() public {
        (IRecipeExecutor.Step memory step, bytes memory data) = _approvalRecipe(100);
        token.setMode(1);
        _run(step, new uint256[](0), data);
        assertEq(token.allowance(address(adapter), address(target)), 100);
        step.amount = _literal(200);
        _save(step);
        for (uint8 mode = 2; mode <= 3; ++mode) {
            token.setMode(mode);
            uint256 beforeCalls = token.calls();
            if (mode == 2) vm.expectRevert(IRecipeExecutor.ApprovalFailed.selector);
            else vm.expectRevert();
            executor.execute(new uint256[](0), _runtime(data));
            assertEq(token.calls(), beforeCalls);
            assertEq(token.allowance(address(adapter), address(target)), 100);
        }
    }

    /// forge-config: default.isolate = true
    function test_ParetoCurrentEpochObservationAndRollback() public {
        address queue = address(new RecipeParetoQueue(address(token)));
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(token), abi.encodeCall(IERC20.approve, (queue, uint256(1 ether))));
        actions[1] = _action(queue, abi.encodeCall(RecipeParetoQueue.requestWithdraw, (uint256(1 ether))));
        bytes32[] memory leaves = _publishPair(actions);
        IRecipeExecutor.Step memory step;
        step.kind = IRecipeExecutor.Kind.Manage;
        step.amount = _literal(1);
        step.data = abi.encode(leaves, new IRecipeExecutor.Binding[][](2));
        step.beforeExpressions = new IRecipeExecutor.Expression[](2);
        step.beforeExpressions[0] = _read(_query(queue, abi.encodeWithSignature("epochNumber()"), _none(), 0));
        step.beforeExpressions[1] = _expression(IRecipeExecutor.Operation.Add, _result(0), _literal(1), _literal(0));
        step.observations = _observations(
            _query(
                queue,
                abi.encodeWithSignature("userWithdrawalsEpochs(address,uint256)", address(adapter), 0),
                _bindings(36, _result(1)),
                0
            ),
            IRecipeExecutor.ObservationKind.Increase
        );
        step.checksAfter = _checks(_result(2), _literal(1 ether), IRecipeExecutor.Comparison.Equal);
        deal(address(token), address(adapter), 4 ether);
        _run(step, new uint256[](0), abi.encode(actions));
        vm.snapshotGasLastCall("RecipeExecutor", "executeNativeEpochReceipt");
        assertEq(RecipeParetoQueue(queue).userWithdrawalsEpochs(address(adapter), 1), 1 ether);
        RecipeParetoQueue(queue).setEpoch(9);
        executor.execute(new uint256[](0), _runtime(abi.encode(actions)));
        executor.execute(new uint256[](0), _runtime(abi.encode(actions)));
        assertEq(RecipeParetoQueue(queue).userWithdrawalsEpochs(address(adapter), 10), 2 ether);
        for (uint256 multiplier; multiplier <= 2; multiplier += 2) {
            RecipeParetoQueue(queue).setReceiptMultiplier(multiplier);
            vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
            executor.execute(new uint256[](0), _runtime(abi.encode(actions)));
            assertEq(token.balanceOf(address(adapter)), 1 ether);
            assertEq(token.allowance(address(adapter), queue), 0);
            assertEq(RecipeParetoQueue(queue).userWithdrawalsEpochs(address(adapter), 10), 2 ether);
        }
    }

    function _save(IRecipeExecutor.Step memory step) internal {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = step;
        executor.setRecipe(recipe);
    }

    function _run(IRecipeExecutor.Step memory step, uint256[] memory inputs, bytes memory data)
        internal
        returns (uint256[] memory)
    {
        _save(step);
        return executor.execute(inputs, _runtime(data));
    }

    function _runtime(bytes memory data) internal pure returns (bytes[] memory runtime) {
        runtime = new bytes[](1);
        runtime[0] = data;
    }

    function _literal(uint256 value) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value(IRecipeExecutor.Source.Literal, value);
    }

    function _input(uint256 index) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value(IRecipeExecutor.Source.Input, index);
    }

    function _result(uint256 index) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value(IRecipeExecutor.Source.Result, index);
    }

    function _expression(
        IRecipeExecutor.Operation operation,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b,
        IRecipeExecutor.Value memory c
    ) internal pure returns (IRecipeExecutor.Expression memory) {
        return IRecipeExecutor.Expression(operation, a, b, c, "");
    }

    function _read(IRecipeExecutor.Query memory query)
        internal
        pure
        returns (IRecipeExecutor.Expression memory expression)
    {
        expression.operation = IRecipeExecutor.Operation.Read;
        expression.data = abi.encode(query);
    }

    function _query(address recipient, bytes memory data, IRecipeExecutor.Binding[] memory bindings, uint256 offset)
        internal
        pure
        returns (IRecipeExecutor.Query memory)
    {
        return IRecipeExecutor.Query(recipient, data, bindings, offset);
    }

    function _valueQuery() internal view returns (IRecipeExecutor.Query memory) {
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
        bindings[0] = IRecipeExecutor.Binding(offset, value);
    }

    function _checks(
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b,
        IRecipeExecutor.Comparison comparison
    ) internal pure returns (IRecipeExecutor.Check[] memory checks) {
        checks = new IRecipeExecutor.Check[](1);
        checks[0] = IRecipeExecutor.Check(a, b, comparison);
    }

    function _observations(IRecipeExecutor.Query memory query, IRecipeExecutor.ObservationKind kind)
        internal
        pure
        returns (IRecipeExecutor.Observation[] memory observations)
    {
        observations = new IRecipeExecutor.Observation[](1);
        observations[0] = IRecipeExecutor.Observation(query, kind);
    }

    function _invoke(bytes4 selector, IRecipeExecutor.Binding[] memory bindings)
        internal
        view
        returns (IRecipeExecutor.Step memory step)
    {
        step.kind = IRecipeExecutor.Kind.Invoke;
        step.data = abi.encode(address(target), selector, bindings);
    }

    function _action(address recipient, bytes memory data) internal pure returns (IMerkleAdapter.Action memory) {
        return IMerkleAdapter.Action(recipient, 0, data, new bytes(data.length), new bytes32[](0));
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
        returns (IRecipeExecutor.Step memory step, bytes memory data)
    {
        _publish(action);
        step.kind = IRecipeExecutor.Kind.Manage;
        step.amount = _literal(1);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        step.data = abi.encode(leaves, new IRecipeExecutor.Binding[][](1));
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        actions[0] = action;
        data = abi.encode(actions);
    }

    function _approvalRecipe(uint256 amount) internal returns (IRecipeExecutor.Step memory step, bytes memory data) {
        IMerkleAdapter.Action memory action =
            _action(address(token), abi.encodeCall(IERC20.approve, (address(target), uint256(0))));
        for (uint256 i = 36; i < 68; ++i) {
            action.dataMask[i] = 0xff;
        }
        _publish(action);
        step.kind = IRecipeExecutor.Kind.Approve;
        step.amount = _literal(amount);
        step.data = abi.encode(address(token), address(target), _leaf(action));
        data = abi.encode(IRecipeExecutor.Permission(action.dataMask, action.proof));
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

contract RecipeTarget {
    function echo(uint256 amount) public pure returns (uint256) {
        return amount;
    }
    uint256 public value;
    uint256 public other;
    address public sender;

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
        return mode != 2;
    }
}
