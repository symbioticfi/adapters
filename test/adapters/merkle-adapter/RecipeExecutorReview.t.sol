// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {Token} from "../../mocks/Token.sol";
import {RecipeExecutor} from "../../../src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {MerkleAdapterVerifier} from "../../../src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "../../../src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Test} from "forge-std/Test.sol";

contract RecipeReviewTarget {
    uint256 public recorded;
    address public caller;

    function record(uint256 amount) public {
        recorded = amount;
        caller = msg.sender;
    }

    function raw(bytes memory data) public pure {
        assembly ("memory-safe") {
            return(add(data, 32), mload(data))
        }
    }
}

contract RecipeReviewOwner {
    address public executor;
    bool public checked;

    function configure(address newExecutor, address newCaller, IRecipeExecutor.Step[] calldata recipe) public {
        executor = newExecutor;
        RecipeExecutor(executor).setCaller(newCaller);
        RecipeExecutor(executor).setRecipe(recipe);
    }

    function probe() public {
        require(executor == msg.sender);
        IRecipeExecutor.Step[] memory empty = new IRecipeExecutor.Step[](0);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(RecipeExecutor.setRecipe, (empty));
        calls[1] = abi.encodeCall(RecipeExecutor.setCaller, (address(0)));
        calls[2] = abi.encodeCall(RecipeExecutor.execute, (new uint256[](0), new bytes[](0)));
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory result) = executor.call(calls[i]);
            require(!success);
            require(bytes4(result) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        }
        checked = true;
    }
}

contract RecipeExecutorReviewTest is Test {
    RecipeExecutor internal executor;
    RecipeReviewTarget internal target;

    function setUp() public {
        executor = new RecipeExecutor(address(this), address(1));
        executor.setCaller(address(this));
        target = new RecipeReviewTarget();
    }

    function testFuzz_StorageCopiesNestedConfiguration(uint8 kind, uint256 amount, bytes memory data) public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](2);
        recipe[0] = _invoke(address(target), RecipeReviewTarget.record.selector);
        recipe[0].amount = IRecipeExecutor.Value(IRecipeExecutor.Source(amount % 3), amount);
        recipe[0].kind = IRecipeExecutor.Kind(kind % 3);
        recipe[0].data = data;
        recipe[0].beforeExpressions = new IRecipeExecutor.Expression[](1);
        recipe[0].beforeExpressions[0].data = data;
        recipe[0].checksBefore = new IRecipeExecutor.Check[](1);
        recipe[0].checksBefore[0].a = _literal(amount);
        recipe[0].observations = new IRecipeExecutor.Observation[](1);
        recipe[0].observations[0].query.data = data;
        recipe[0].observations[0].query.bindings = new IRecipeExecutor.Binding[](1);
        recipe[0].observations[0].query.bindings[0] = IRecipeExecutor.Binding(amount, _literal(amount));
        recipe[0].afterExpressions = recipe[0].beforeExpressions;
        recipe[0].checksAfter = recipe[0].checksBefore;
        recipe[1] = _invoke(address(target), RecipeReviewTarget.record.selector);
        executor.setRecipe(recipe);
        assertEq(executor.steps(0), abi.encode(recipe[0]));
        assertEq(executor.steps(1), abi.encode(recipe[1]));
        IRecipeExecutor.Step[] memory shorter = new IRecipeExecutor.Step[](1);
        shorter[0] = recipe[1];
        executor.setRecipe(shorter);
        assertEq(executor.steps(0), abi.encode(shorter[0]));
        vm.expectRevert();
        executor.steps(1);
        executor.setRecipe(recipe);
        assertEq(executor.steps(0), abi.encode(recipe[0]));
        executor.setRecipe(new IRecipeExecutor.Step[](0));
        assertEq(executor.execute(new uint256[](0), new bytes[](0)).length, 0);
    }

    function testFuzz_BoundStaticArgumentReplacesRuntimeAmount(uint256 amount) public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = _invoke(address(target), RecipeReviewTarget.record.selector);
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](1);
        bindings[0] = IRecipeExecutor.Binding(4, _literal(amount));
        recipe[0].data = abi.encode(address(target), RecipeReviewTarget.record.selector, bindings);
        executor.setRecipe(recipe);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encodeCall(RecipeReviewTarget.record, (amount ^ 1));
        assertEq(executor.execute(new uint256[](0), runtime).length, 0);
        assertEq(target.recorded(), amount);
        assertEq(target.caller(), address(executor));
    }

    function testFuzz_WordReadsMatchBytes(bytes memory data, bytes32 tail, uint256 offset) public {
        data = bytes.concat(data, tail);
        _assertWordReads(data, bound(offset, 0, data.length - 32));
        _assertWordReads(data, data.length - 32);
    }

    function test_WordReadsRequireCompleteWords() public {
        for (uint256 length; length <= 33; ++length) {
            _assertWordReads(new bytes(length), 0);
        }
        _assertWordReads(new bytes(33), 1);
        for (uint256 remaining; remaining < 32; ++remaining) {
            _assertWordReads(new bytes(64), 64 - remaining);
        }
        _assertWordReads(new bytes(64), 65);
        _assertWordReads(new bytes(64), type(uint256).max);
    }

    function test_PostconditionFailureRollsBackInvokedState() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = _invoke(address(target), RecipeReviewTarget.record.selector);
        recipe[0].observations = new IRecipeExecutor.Observation[](1);
        recipe[0].observations[0] = IRecipeExecutor.Observation(
            IRecipeExecutor.Query(
                address(target), abi.encodeWithSignature("recorded()"), new IRecipeExecutor.Binding[](0), 0
            ),
            IRecipeExecutor.ObservationKind.After
        );
        recipe[0].checksAfter = new IRecipeExecutor.Check[](1);
        recipe[0].checksAfter[0] = IRecipeExecutor.Check(_result(0), _literal(1), IRecipeExecutor.Comparison.Equal);
        executor.setRecipe(recipe);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encodeCall(RecipeReviewTarget.record, (2));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        executor.execute(new uint256[](0), runtime);
        assertEq(target.recorded(), 0);
        assertEq(target.caller(), address(0));
    }

    function test_OwnerCallbackCannotChangeConfigurationOrReenter() public {
        RecipeReviewOwner owner = new RecipeReviewOwner();
        executor = new RecipeExecutor(address(owner), address(1));
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = _invoke(address(owner), RecipeReviewOwner.probe.selector);
        owner.configure(address(executor), address(this), recipe);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encodeCall(RecipeReviewOwner.probe, ());
        executor.execute(new uint256[](0), runtime);
        assertTrue(owner.checked());
        assertEq(executor.steps(0), abi.encode(recipe[0]));
        assertEq(executor.caller(), address(this));
    }

    function _assertWordReads(bytes memory data, uint256 offset) internal {
        bool valid = data.length >= 32 && offset <= data.length - 32;
        uint256 expected;
        if (valid) {
            for (uint256 i; i < 32; ++i) {
                expected = (expected << 8) | uint8(data[offset + i]);
            }
        }
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0].beforeExpressions = new IRecipeExecutor.Expression[](1);
        recipe[0].beforeExpressions[0].operation = IRecipeExecutor.Operation.Read;
        recipe[0].beforeExpressions[0].data = abi.encode(
            IRecipeExecutor.Query(
                address(target),
                abi.encodeCall(RecipeReviewTarget.raw, (data)),
                new IRecipeExecutor.Binding[](0),
                offset
            )
        );
        executor.setRecipe(recipe);
        if (!valid) vm.expectRevert();
        uint256[] memory values = executor.execute(new uint256[](0), new bytes[](1));
        if (valid) assertEq(values[0], expected);
    }

    function _invoke(address recipient, bytes4 selector) internal pure returns (IRecipeExecutor.Step memory step) {
        step.kind = IRecipeExecutor.Kind.Invoke;
        step.data = abi.encode(recipient, selector, new IRecipeExecutor.Binding[](0));
    }

    function _literal(uint256 value) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value(IRecipeExecutor.Source.Literal, value);
    }

    function _result(uint256 index) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value(IRecipeExecutor.Source.Result, index);
    }
}

contract RecipeExecutorEncodingTest is CapabilityTestBase {
    address internal executor;
    address internal target;

    function setUp() public {
        _deployAdapter(address(new Token("Asset")));
        executor = address(new RecipeExecutor(address(this), address(adapter)));
        RecipeExecutor(executor).setCaller(address(this));
        target = address(new RecipeReviewTarget());
    }

    function test_ManageTrailingBytesDoNotChangeAuthorization() public {
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        actions[0] = _action(target, 7);
        bytes32[] memory leaves = _publish(actions);
        _configure(leaves, new IRecipeExecutor.Binding[][](1));
        _execute(bytes.concat(abi.encode(actions), hex"deadbeef"));
        assertEq(RecipeReviewTarget(target).recorded(), 7);
        assertEq(RecipeReviewTarget(target).caller(), address(adapter));

        actions[0].data = abi.encodeCall(RecipeReviewTarget.record, (8));
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(bytes.concat(abi.encode(actions), hex"deadbeef"));
        assertEq(RecipeReviewTarget(target).recorded(), 7);
    }

    function testFuzz_ManageRelocatedTailChecksFinalBoundLeaf(uint128 amount) public {
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        actions[0] = _action(target, amount);
        bytes32[] memory leaves = _publish(actions);
        IRecipeExecutor.Binding[][] memory bindings = _bindings(amount, 1);
        _configure(leaves, bindings);
        actions[0].data = abi.encodeCall(RecipeReviewTarget.record, (0));
        bytes memory canonical = abi.encode(actions);
        bytes memory relocated = bytes.concat(canonical, Bytes.slice(abi.encode(actions[0].data), 32));
        Bytes.replace(relocated, 160, abi.encode(canonical.length - 96));
        assertEq(abi.encode(abi.decode(relocated, (IMerkleAdapter.Action[]))), canonical);

        _execute(relocated);
        assertEq(RecipeReviewTarget(target).recorded(), amount);
        bindings[0][0].value.value = uint256(amount) ^ 1;
        _configure(leaves, bindings);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(relocated);
        assertEq(RecipeReviewTarget(target).recorded(), amount);
    }

    function test_ManageSharedTailsKeepActionsIndependent() public {
        address second = address(new RecipeReviewTarget());
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(target, 7);
        actions[1] = _action(second, 9);
        bytes32[] memory leaves = _publish(actions);
        IRecipeExecutor.Binding[][] memory bindings = _bindings(7, 2);
        bindings[1][0].value.value = 9;
        _configure(leaves, bindings);
        actions[0].data = abi.encodeCall(RecipeReviewTarget.record, (0));
        actions[1].data = actions[0].data;
        bytes memory canonical = abi.encode(actions);
        bytes memory sharedData = Bytes.slice(abi.encode(actions[0].data), 32);
        bytes memory shared = bytes.concat(canonical, sharedData, Bytes.slice(abi.encode(actions[0].dataMask), 32));
        for (uint256 i; i < 2; ++i) {
            uint256 head = 64 + abi.decode(Bytes.slice(canonical, 64 + 32 * i, 96 + 32 * i), (uint256));
            Bytes.replace(shared, head + 64, abi.encode(canonical.length - head));
            Bytes.replace(shared, head + 96, abi.encode(canonical.length + sharedData.length - head));
        }
        assertEq(abi.encode(abi.decode(shared, (IMerkleAdapter.Action[]))), canonical);

        _execute(shared);
        assertEq(RecipeReviewTarget(target).recorded(), 7);
        assertEq(RecipeReviewTarget(second).recorded(), 9);
        assertEq(RecipeReviewTarget(target).caller(), address(adapter));
        assertEq(RecipeReviewTarget(second).caller(), address(adapter));
    }

    function test_ManageSharedDataAndMaskTailPreservesCommittedMask() public {
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        actions[0] = _action(target, 7);
        actions[0].dataMask = abi.encodeCall(RecipeReviewTarget.record, (0));
        bytes32[] memory leaves = _publish(actions);
        _configure(leaves, _bindings(7, 1));
        actions[0].data = actions[0].dataMask;
        bytes memory canonical = abi.encode(actions);
        bytes memory shared = bytes.concat(canonical, Bytes.slice(abi.encode(actions[0].data), 32));
        Bytes.replace(shared, 160, abi.encode(canonical.length - 96));
        Bytes.replace(shared, 192, abi.encode(canonical.length - 96));
        assertEq(abi.encode(abi.decode(shared, (IMerkleAdapter.Action[]))), canonical);

        _execute(shared);
        assertEq(RecipeReviewTarget(target).recorded(), 7);
        assertEq(RecipeReviewTarget(target).caller(), address(adapter));
    }

    function _action(address recipient, uint256 amount) internal pure returns (IMerkleAdapter.Action memory) {
        bytes memory data = abi.encodeCall(RecipeReviewTarget.record, (amount));
        return IMerkleAdapter.Action(recipient, 0, data, new bytes(data.length), new bytes32[](0));
    }

    function _publish(IMerkleAdapter.Action[] memory actions) internal returns (bytes32[] memory leaves) {
        leaves = new bytes32[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            leaves[i] = MerkleAdapterVerifier.leaf(actions[i].target, 0, actions[i].data, actions[i].dataMask);
            adapter.grantRole(leaves[i], executor);
        }
        bytes32 root = leaves[0];
        if (actions.length == 2) {
            root = leaves[0] < leaves[1]
                ? keccak256(abi.encodePacked(leaves[0], leaves[1]))
                : keccak256(abi.encodePacked(leaves[1], leaves[0]));
            for (uint256 i; i < 2; ++i) {
                actions[i].proof = new bytes32[](1);
                actions[i].proof[0] = leaves[1 - i];
            }
        }
        roots.setRoot(address(adapter), root);
        adapter.acceptRoot(root);
    }

    function _bindings(uint256 amount, uint256 length)
        internal
        pure
        returns (IRecipeExecutor.Binding[][] memory bindings)
    {
        bindings = new IRecipeExecutor.Binding[][](length);
        for (uint256 i; i < length; ++i) {
            bindings[i] = new IRecipeExecutor.Binding[](1);
            bindings[i][0] = IRecipeExecutor.Binding(4, IRecipeExecutor.Value(IRecipeExecutor.Source.Literal, amount));
        }
    }

    function _configure(bytes32[] memory leaves, IRecipeExecutor.Binding[][] memory bindings) internal {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0].kind = IRecipeExecutor.Kind.Manage;
        recipe[0].amount = IRecipeExecutor.Value(IRecipeExecutor.Source.Literal, 1);
        recipe[0].data = abi.encode(leaves, bindings);
        RecipeExecutor(executor).setRecipe(recipe);
    }

    function _execute(bytes memory actions) internal {
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = actions;
        RecipeExecutor(executor).execute(new uint256[](0), runtime);
    }
}
