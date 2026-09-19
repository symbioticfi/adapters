// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";

import {RecipeExecutor} from "../../../src/contracts/periphery/RecipeExecutor.sol";
import {ImmutableFactory} from "../../../src/contracts/common/ImmutableFactory.sol";

import {MerkleAdapterVerifier} from "../../../src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IExecutor} from "../../../src/interfaces/periphery/IExecutor.sol";
import {IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "../../../src/interfaces/periphery/IRecipeExecutor.sol";

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

    function test_FuzzArithmetic(uint128 x, uint128 y, uint128 divisor) public {
        divisor = uint128(bound(divisor, 1, type(uint128).max));
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](8);
        recipe[0] = _step(IRecipeExecutor.Operation.Input, 0, 0, 0);
        recipe[1] = _step(IRecipeExecutor.Operation.Constant, y, 0, 0);
        recipe[2] = _step(IRecipeExecutor.Operation.Constant, divisor, 0, 0);
        recipe[3] = _step(IRecipeExecutor.Operation.Add, 0, 1, 0);
        recipe[4] = _step(IRecipeExecutor.Operation.Subtract, 3, 1, 0);
        recipe[5] = _step(IRecipeExecutor.Operation.Minimum, 0, 1, 0);
        recipe[6] = _step(IRecipeExecutor.Operation.MulDiv, 0, 1, 2);
        recipe[7] = _step(IRecipeExecutor.Operation.Equal, 0, 4, 0);
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = x;
        executor.setRecipe(recipe);
        uint256[] memory values = executor.execute(inputs, new bytes[](8));
        assertEq(values[3], uint256(x) + y);
        assertEq(values[4], x);
        assertEq(values[5], x < y ? x : y);
        assertEq(values[6], uint256(x) * y / divisor);
    }

    function test_UnconfiguredRecipeIsEmpty() public {
        assertEq(executor.execute(new uint256[](0), new bytes[](0)).length, 0);
    }

    function test_RejectsForwardReference() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = _step(IRecipeExecutor.Operation.Add, 0, 0, 0);
        executor.setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
        executor.execute(new uint256[](0), new bytes[](1));
    }

    function test_RejectsForwardMultiplierAndDenominatorReferences() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](3);
        recipe[0] = _step(IRecipeExecutor.Operation.Constant, 7, 0, 0);
        recipe[1] = _step(IRecipeExecutor.Operation.Constant, 1, 0, 0);
        recipe[2] = _step(IRecipeExecutor.Operation.MulDiv, 0, 2, 1);
        executor.setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
        executor.execute(new uint256[](0), new bytes[](3));
        recipe[2].b = 1;
        recipe[2].c = 2;
        executor.setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.InvalidReference.selector);
        executor.execute(new uint256[](0), new bytes[](3));
    }

    /// forge-config: default.isolate = true
    function test_ChecksAndCallsProduceZeroResults() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](6);
        recipe[0] = _step(IRecipeExecutor.Operation.Constant, 7, 0, 0);
        recipe[1] = _step(IRecipeExecutor.Operation.Equal, 0, 0, 0);
        recipe[2] = _step(IRecipeExecutor.Operation.LessOrEqual, 1, 0, 0);
        recipe[3] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Invoke,
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            abi.encode(address(target), RecipeTarget.set.selector)
        );
        recipe[4] = _step(IRecipeExecutor.Operation.Add, 1, 2, 0);
        recipe[5] = _step(IRecipeExecutor.Operation.Add, 3, 4, 0);
        bytes[] memory runtime = new bytes[](6);
        runtime[3] = abi.encodeCall(RecipeTarget.set, (7));
        executor.setRecipe(recipe);
        uint256[] memory values = executor.execute(new uint256[](0), runtime);
        vm.snapshotGasLastCall("RecipeExecutor", "executeChecksAndInvoke");
        assertEq(values[5], 0);
        assertEq(target.value(), 7);
    }

    /// forge-config: default.isolate = true
    function test_ConfigurationAndFactory() public {
        ImmutableFactory factory = new ImmutableFactory(type(RecipeExecutor).creationCode);
        address instance = factory.create(abi.encode(address(this), address(adapter)));
        assertTrue(factory.isEntity(instance));
        assertEq(RecipeExecutor(instance).adapter(), address(adapter));
        assertEq(RecipeExecutor(instance).owner(), address(this));
        assertEq(RecipeExecutor(instance).caller(), address(0));
        executor.setCaller(address(123));
        vm.snapshotGasLastCall("RecipeExecutor", "setCaller");
        assertEq(executor.caller(), address(123));
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = _step(IRecipeExecutor.Operation.Constant, 10, 0, 0);
        executor.setRecipe(recipe);
        vm.snapshotGasLastCall("RecipeExecutor", "setRecipe");
        executor.setRecipe(new IRecipeExecutor.Step[](0));
        vm.snapshotGasLastCall("RecipeExecutor", "setRecipeClear");
        vm.prank(address(123));
        executor.execute(new uint256[](0), new bytes[](0));
        vm.snapshotGasLastCall("RecipeExecutor", "executeEmpty");
    }

    function test_OwnerAndCallerBoundaries() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](0);
        vm.startPrank(address(123));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(123)));
        executor.setRecipe(recipe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(123)));
        executor.setCaller(address(123));
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.execute(new uint256[](0), new bytes[](0));
        vm.stopPrank();
        executor.setCaller(address(0));
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.execute(new uint256[](0), new bytes[](0));
    }

    function test_RecipeIsCopiedToStorage() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = _step(IRecipeExecutor.Operation.Constant, 10, 0, 0);
        executor.setRecipe(recipe);
        recipe[0].a = 11;
        recipe[0].data = hex"01";
        assertEq(executor.execute(new uint256[](0), new bytes[](1))[0], 10);
        (IRecipeExecutor.Operation operation, uint256 a, uint256 b, uint256 c, bytes memory data) = executor.steps(0);
        assertEq(uint256(operation), uint256(IRecipeExecutor.Operation.Constant));
        assertEq(a, 10);
        assertEq(b, 0);
        assertEq(c, 0);
        assertEq(data, "");
        executor.setRecipe(recipe);
        assertEq(executor.execute(new uint256[](0), new bytes[](1))[0], 11);
    }

    /// forge-config: default.isolate = true
    function test_RecipeReplacementShrinksGrowsAndClearsDynamicData() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](3);
        for (uint256 i; i < recipe.length; ++i) {
            recipe[i] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, i + 1, i + 2, i + 3, new bytes(96));
            recipe[i].data[95] = bytes1(uint8(i + 1));
        }
        executor.setRecipe(recipe);
        IRecipeExecutor.Step[] memory shorter = new IRecipeExecutor.Step[](1);
        shorter[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, 9, 0, 0, hex"ab");
        executor.setRecipe(shorter);
        vm.snapshotGasLastCall("RecipeExecutor", "setRecipeShorter");
        (,,,, bytes memory data) = executor.steps(0);
        assertEq(data, hex"ab");
        assertEq(executor.execute(new uint256[](0), new bytes[](1))[0], 9);
        vm.expectRevert();
        executor.steps(1);

        recipe[0].data = "";
        recipe[1].data = hex"cd";
        recipe[2].data = hex"ef";
        executor.setRecipe(recipe);
        vm.snapshotGasLastCall("RecipeExecutor", "setRecipeLonger");
        for (uint256 i; i < recipe.length; ++i) {
            (IRecipeExecutor.Operation operation, uint256 a, uint256 b, uint256 c, bytes memory storedData) =
                executor.steps(i);
            assertEq(uint256(operation), uint256(recipe[i].operation));
            assertEq(a, recipe[i].a);
            assertEq(b, recipe[i].b);
            assertEq(c, recipe[i].c);
            assertEq(storedData, recipe[i].data);
        }
        executor.setRecipe(new IRecipeExecutor.Step[](0));
        assertEq(executor.execute(new uint256[](0), new bytes[](0)).length, 0);
        vm.expectRevert();
        executor.steps(0);
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(new uint256[](0), new bytes[](3));

        executor.setRecipe(new IRecipeExecutor.Step[](3));
        for (uint256 i; i < 3; ++i) {
            (IRecipeExecutor.Operation operation, uint256 a, uint256 b, uint256 c, bytes memory storedData) =
                executor.steps(i);
            assertEq(uint256(operation), 0);
            assertEq(a, 0);
            assertEq(b, 0);
            assertEq(c, 0);
            assertEq(storedData, "");
        }
    }

    function test_ExecutionUsesCurrentRecipeWithPreviouslyPreparedRuntime() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Invoke, 0, 0, 0, abi.encode(address(target), RecipeTarget.set.selector)
        );
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encodeCall(RecipeTarget.set, (7));
        executor.setRecipe(recipe);
        address replacement = address(new RecipeTarget());
        recipe[0].data = abi.encode(replacement, RecipeTarget.set.selector);
        executor.setRecipe(recipe);
        executor.execute(new uint256[](0), runtime);
        assertEq(target.value(), 0);
        assertEq(RecipeTarget(replacement).value(), 7);
    }

    function test_RuntimeLengthAndMissingInput() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = _step(IRecipeExecutor.Operation.Input, 0, 0, 0);
        executor.setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(new uint256[](0), new bytes[](0));
        vm.expectRevert(stdError.indexOOBError);
        executor.execute(new uint256[](0), new bytes[](1));
    }

    function test_ArithmeticFailures() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](3);
        recipe[0] = _step(IRecipeExecutor.Operation.Constant, type(uint256).max, 0, 0);
        recipe[1] = _step(IRecipeExecutor.Operation.Constant, 1, 0, 0);
        recipe[2] = _step(IRecipeExecutor.Operation.Add, 0, 1, 0);
        executor.setRecipe(recipe);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(new uint256[](0), new bytes[](3));
        recipe[2] = _step(IRecipeExecutor.Operation.Subtract, 1, 0, 0);
        executor.setRecipe(recipe);
        vm.expectRevert(stdError.arithmeticError);
        executor.execute(new uint256[](0), new bytes[](3));
        recipe[1].a = 0;
        recipe[2] = _step(IRecipeExecutor.Operation.MulDiv, 1, 1, 1);
        executor.setRecipe(recipe);
        vm.expectRevert(stdError.divisionError);
        executor.execute(new uint256[](0), new bytes[](3));
    }

    /// forge-config: default.isolate = true
    function test_ReadSelectsWordAndCannotWrite() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Read, 32, 0, 0, abi.encode(address(target), abi.encodeCall(RecipeTarget.pair, ()))
        );
        executor.setRecipe(recipe);
        uint256[] memory values = executor.execute(new uint256[](0), new bytes[](1));
        vm.snapshotGasLastCall("RecipeExecutor", "executeRead");
        assertEq(values[0], 42);
        recipe[0].a = 33;
        executor.setRecipe(recipe);
        vm.expectRevert();
        executor.execute(new uint256[](0), new bytes[](1));
        recipe[0].data = abi.encode(address(target), abi.encodeCall(RecipeTarget.set, (1)));
        executor.setRecipe(recipe);
        vm.expectRevert();
        executor.execute{gas: 500_000}(new uint256[](0), new bytes[](1));
        assertEq(target.value(), 0);
    }

    function test_CalldataWordBounds(uint256 amount) public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = _step(IRecipeExecutor.Operation.Calldata, 0, 4, 0);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encodeCall(RecipeTarget.set, (amount));
        executor.setRecipe(recipe);
        assertEq(executor.execute(new uint256[](0), runtime)[0], amount);
        runtime[0] = hex"12345678";
        vm.expectRevert();
        executor.execute(new uint256[](0), runtime);
        recipe[0].b = type(uint256).max;
        executor.setRecipe(recipe);
        runtime[0] = abi.encode(amount);
        vm.expectRevert();
        executor.execute(new uint256[](0), runtime);
    }

    /// forge-config: default.isolate = true
    function test_InvokeAndChecksRollback() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](4);
        recipe[0] = _step(IRecipeExecutor.Operation.Calldata, 2, 4, 0);
        recipe[1] = _step(IRecipeExecutor.Operation.Constant, 10, 0, 0);
        recipe[2] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Invoke, 0, 0, 0, abi.encode(address(target), RecipeTarget.set.selector)
        );
        recipe[3] = _step(IRecipeExecutor.Operation.LessOrEqual, 0, 1, 0);
        bytes[] memory runtime = new bytes[](4);
        runtime[2] = abi.encodeCall(RecipeTarget.set, (11));
        executor.setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        executor.execute(new uint256[](0), runtime);
        assertEq(target.value(), 0);
        runtime[2] = abi.encodeCall(RecipeTarget.set, (10));
        executor.execute(new uint256[](0), runtime);
        vm.snapshotGasLastCall("RecipeExecutor", "executeCalldataAndInvoke");
        assertEq(target.value(), 10);
        assertEq(target.sender(), address(executor));
        runtime[2] = abi.encodeCall(RecipeTarget.pair, ());
        recipe[0] = _step(IRecipeExecutor.Operation.Constant, 0, 0, 0);
        executor.setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.InvalidCall.selector);
        executor.execute(new uint256[](0), runtime);
        runtime[2] = hex"1234";
        vm.expectRevert(IRecipeExecutor.InvalidCall.selector);
        executor.execute(new uint256[](0), runtime);
        recipe[3] = _step(IRecipeExecutor.Operation.Equal, 0, 1, 0);
        executor.setRecipe(recipe);
        runtime[2] = abi.encodeCall(RecipeTarget.set, (7));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        executor.execute(new uint256[](0), runtime);
        assertEq(target.value(), 10);
    }

    /// forge-config: default.isolate = true
    function test_ManageUsesAdapterAndCurrentRole() public {
        IMerkleAdapter.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (, bytes[] memory runtime) = _manageRecipe(action);
        executor.execute(new uint256[](0), runtime);
        vm.snapshotGasLastCall("RecipeExecutor", "executeManage");
        assertEq(target.value(), 7);
        assertEq(target.sender(), address(adapter));
        adapter.revokeRole(_leaf(action), address(executor));
        vm.expectRevert();
        executor.execute(new uint256[](0), runtime);
        adapter.grantRole(_leaf(action), address(executor));
        roots.setRoot(address(adapter), bytes32(uint256(123)));
        adapter.acceptRoot(bytes32(uint256(123)));
        vm.expectRevert();
        executor.execute(new uint256[](0), runtime);
    }

    function test_ManageRejectsChangedLeafNativeValueAndCount() public {
        IMerkleAdapter.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (, bytes[] memory runtime) = _manageRecipe(action);
        IMerkleAdapter.Action[] memory calls = new IMerkleAdapter.Action[](1);
        action.data = abi.encodeCall(RecipeTarget.set, (8));
        calls[0] = action;
        runtime[1] = abi.encode(calls);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(new uint256[](0), runtime);
        action.data = abi.encodeCall(RecipeTarget.set, (7));
        action.value = 1;
        calls[0] = action;
        runtime[1] = abi.encode(calls);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(new uint256[](0), runtime);
        runtime[1] = abi.encode(new IMerkleAdapter.Action[](0));
        vm.expectRevert(IRecipeExecutor.InvalidRuntime.selector);
        executor.execute(new uint256[](0), runtime);
    }

    /// forge-config: default.isolate = true
    function test_ManageZeroGuardSkipsUnavailableSource() public {
        IMerkleAdapter.Action memory action = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        (IRecipeExecutor.Step[] memory recipe, bytes[] memory runtime) = _manageRecipe(action);
        recipe[0].a = 0;
        runtime[1] = "";
        executor.setRecipe(recipe);
        executor.execute(new uint256[](0), runtime);
        vm.snapshotGasLastCall("RecipeExecutor", "executeManageSkipped");
        assertEq(target.value(), 0);
    }

    function test_ManageGroupCannotReorderIndividuallyApprovedLeaves() public {
        IMerkleAdapter.Action[] memory calls = new IMerkleAdapter.Action[](2);
        calls[0] = _action(address(target), abi.encodeCall(RecipeTarget.set, (7)));
        calls[1] = _action(address(target), abi.encodeCall(RecipeTarget.set, (8)));
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(calls[0]);
        leaves[1] = _leaf(calls[1]);
        bytes32 root = leaves[0] < leaves[1]
            ? keccak256(abi.encodePacked(leaves[0], leaves[1]))
            : keccak256(abi.encodePacked(leaves[1], leaves[0]));
        roots.setRoot(address(adapter), root);
        adapter.acceptRoot(root);
        for (uint256 i; i < 2; ++i) {
            calls[i].proof = new bytes32[](1);
            calls[i].proof[0] = leaves[1 - i];
            adapter.grantRole(leaves[i], address(executor));
        }
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](2);
        recipe[0] = _step(IRecipeExecutor.Operation.Constant, 1, 0, 0);
        recipe[1] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Manage, 0, 0, 0, abi.encode(leaves));
        bytes[] memory runtime = new bytes[](2);
        runtime[1] = abi.encode(calls);
        executor.setRecipe(recipe);
        executor.execute(new uint256[](0), runtime);
        assertEq(target.value(), 8);
        (calls[0], calls[1]) = (calls[1], calls[0]);
        runtime[1] = abi.encode(calls);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        executor.execute(new uint256[](0), runtime);
        assertEq(target.value(), 8);
    }

    /// forge-config: default.isolate = true
    function test_ApprovalFromAdapterResetsAndClears() public {
        uint256 initialCalls = token.calls();
        (IRecipeExecutor.Step[] memory recipe, bytes[] memory runtime) = _approvalRecipe(100);
        executor.execute(new uint256[](0), runtime);
        vm.snapshotGasLastCall("RecipeExecutor", "executeApprove");
        assertEq(token.allowance(address(adapter), address(target)), 100);
        assertEq(token.lastApprover(), address(adapter));
        recipe[0].a = 200;
        executor.setRecipe(recipe);
        executor.execute(new uint256[](0), runtime);
        vm.snapshotGasLastCall("RecipeExecutor", "executeApproveReset");
        assertEq(token.allowance(address(adapter), address(target)), 200);
        assertEq(token.calls(), initialCalls + 3);
        recipe[0].a = 0;
        executor.setRecipe(recipe);
        executor.execute(new uint256[](0), runtime);
        vm.snapshotGasLastCall("RecipeExecutor", "executeApproveClear");
        assertEq(token.allowance(address(adapter), address(target)), 0);
        assertEq(token.calls(), initialCalls + 4);
    }

    function test_ApprovalHandlesNoReturnAndFalse() public {
        (IRecipeExecutor.Step[] memory recipe, bytes[] memory runtime) = _approvalRecipe(100);
        token.setMode(1);
        executor.execute(new uint256[](0), runtime);
        assertEq(token.allowance(address(adapter), address(target)), 100);
        token.setMode(2);
        recipe[0].a = 200;
        executor.setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.ApprovalFailed.selector);
        executor.execute(new uint256[](0), runtime);
        assertEq(token.allowance(address(adapter), address(target)), 100);
    }

    function test_ApprovalRejectsMalformedReturnData() public {
        (, bytes[] memory runtime) = _approvalRecipe(100);
        uint256 callsBefore = token.calls();
        token.setMode(3);
        vm.expectRevert();
        executor.execute(new uint256[](0), runtime);
        assertEq(token.allowance(address(adapter), address(target)), 0);
        assertEq(token.calls(), callsBefore);
    }

    function _manageRecipe(IMerkleAdapter.Action memory action)
        internal
        returns (IRecipeExecutor.Step[] memory recipe, bytes[] memory runtime)
    {
        _publish(action);
        recipe = new IRecipeExecutor.Step[](2);
        recipe[0] = _step(IRecipeExecutor.Operation.Constant, 1, 0, 0);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(action);
        recipe[1] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Manage, 0, 0, 0, abi.encode(leaves));
        IMerkleAdapter.Action[] memory calls = new IMerkleAdapter.Action[](1);
        calls[0] = action;
        runtime = new bytes[](2);
        runtime[1] = abi.encode(calls);
        executor.setRecipe(recipe);
    }

    function _approvalRecipe(uint256 amount)
        internal
        returns (IRecipeExecutor.Step[] memory recipe, bytes[] memory runtime)
    {
        IMerkleAdapter.Action memory action =
            _action(address(token), abi.encodeCall(IERC20.approve, (address(target), uint256(0))));
        for (uint256 i = 36; i < 68; ++i) {
            action.dataMask[i] = 0xff;
        }
        _publish(action);
        recipe = new IRecipeExecutor.Step[](2);
        recipe[0] = _step(IRecipeExecutor.Operation.Constant, amount, 0, 0);
        recipe[1] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Approve, 0, 0, 0, abi.encode(address(token), address(target), _leaf(action))
        );
        runtime = new bytes[](2);
        runtime[1] = abi.encode(IExecutor.Permission(action.dataMask, action.proof));
        executor.setRecipe(recipe);
    }

    function _publish(IMerkleAdapter.Action memory action) internal {
        bytes32 leaf = _leaf(action);
        roots.setRoot(address(adapter), leaf);
        adapter.acceptRoot(leaf);
        adapter.grantRole(leaf, address(executor));
    }

    function _action(address recipient, bytes memory data) internal pure returns (IMerkleAdapter.Action memory) {
        return IMerkleAdapter.Action(recipient, 0, data, new bytes(data.length), new bytes32[](0));
    }

    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        return MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
    }

    function _step(IRecipeExecutor.Operation operation, uint256 a, uint256 b, uint256 c)
        internal
        pure
        returns (IRecipeExecutor.Step memory)
    {
        return IRecipeExecutor.Step(operation, a, b, c, "");
    }
}

contract RecipeTarget {
    uint256 public value;
    address public sender;

    function set(uint256 newValue) public {
        value = newValue;
        sender = msg.sender;
    }

    function pair() public pure returns (uint256, uint256) {
        return (7, 42);
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
