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
import {Vm} from "forge-std/Vm.sol";

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

    function rejectRead() public pure returns (uint256) {
        revert("query reached");
    }

    function echo(uint256 value) public pure returns (uint256) {
        return value;
    }
}

contract RecipeReviewOwner {
    address public executor;
    bool public checked;

    function configure(address newExecutor, address newCaller, IRecipeExecutor.Recipe calldata recipe) public {
        executor = newExecutor;
        RecipeExecutor(executor).setCaller(newCaller);
        RecipeExecutor(executor).setRecipe(recipe);
    }

    function probe() public {
        require(executor == msg.sender);
        IRecipeExecutor.Recipe memory empty;
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(RecipeExecutor.setRecipe, (empty));
        calls[1] = abi.encodeCall(RecipeExecutor.setCaller, (address(0)));
        calls[2] = abi.encodeCall(RecipeExecutor.execute, (empty, new uint256[](0), new bytes[](0)));
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

    function testFuzz_CommitmentAndEventContainCompleteConfiguration(uint8 operation, uint256 amount, bytes memory data)
        public
    {
        IRecipeExecutor.Recipe memory recipe = _recipe(2);
        recipe.queries = new IRecipeExecutor.Query[](1);
        recipe.queries[0] = IRecipeExecutor.Query(address(target), data, new IRecipeExecutor.Binding[](1), amount);
        recipe.queries[0].bindings[0] = IRecipeExecutor.Binding(amount, _literal(amount));
        recipe.steps[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation(operation % 11), data);
        recipe.steps[1] = _call(address(target), abi.encodeCall(RecipeReviewTarget.record, (amount)), _none());
        vm.recordLogs();
        executor.setRecipe(recipe);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(executor));
        assertEq(logs[0].topics[1], keccak256(abi.encode(recipe)));
        assertEq(logs[0].data, abi.encode(recipe));
        assertEq(executor.recipeHash(), keccak256(abi.encode(recipe)));
        assertEq(executor.recipeBlock(), block.number);
        recipe.steps[0].data = bytes.concat(data, hex"01");
        vm.expectRevert(IRecipeExecutor.InvalidRecipe.selector);
        executor.execute(recipe, new uint256[](0), new bytes[](0));
        recipe = _recipe(0);
        executor.setRecipe(recipe);
        assertEq(executor.execute(recipe, new uint256[](0), new bytes[](0)).length, 0);
    }

    function test_ConfigurationUsesTwoSlotsIndependentOfRecipeSize() public {
        IRecipeExecutor.Recipe memory recipe = _recipe(300);
        recipe.queries = new IRecipeExecutor.Query[](30);
        for (uint256 i; i < recipe.steps.length; ++i) {
            recipe.steps[i] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Add, abi.encode(_literal(i), _literal(1)));
        }
        for (uint256 i; i < recipe.queries.length; ++i) {
            recipe.queries[i] = IRecipeExecutor.Query(address(target), new bytes(1000), _none(), i);
        }
        vm.record();
        executor.setRecipe(recipe);
        (, bytes32[] memory writes) = vm.accesses(address(executor));
        assertEq(writes.length, 2);
        assertEq(vm.load(address(executor), bytes32(uint256(2))), keccak256(abi.encode(recipe)));
        assertEq(uint256(vm.load(address(executor), bytes32(uint256(3)))), block.number);
        uint256[] memory values = executor.execute(recipe, new uint256[](0), new bytes[](0));
        assertEq(values.length, 300);
        assertEq(values[299], 300);
        recipe = _recipe(0);
        vm.roll(block.number + 1);
        vm.record();
        executor.setRecipe(recipe);
        (, writes) = vm.accesses(address(executor));
        assertEq(writes.length, 2);
        assertEq(executor.recipeBlock(), block.number);
    }

    function test_RejectsUnconfiguredChangedRecipeAndWrongCallerBeforeQueries() public {
        IRecipeExecutor.Recipe memory recipe = _recipe(1);
        recipe.queries = new IRecipeExecutor.Query[](1);
        recipe.queries[0] =
            IRecipeExecutor.Query(address(target), abi.encodeCall(RecipeReviewTarget.rejectRead, ()), _none(), 0);
        recipe.steps[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Read, abi.encode(uint256(0)));
        vm.expectRevert(IRecipeExecutor.InvalidRecipe.selector);
        executor.execute(recipe, new uint256[](0), new bytes[](0));
        executor.setRecipe(recipe);
        vm.prank(address(123));
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.execute(recipe, new uint256[](0), new bytes[](0));
        recipe.queries[0].offset = 32;
        vm.expectRevert(IRecipeExecutor.InvalidRecipe.selector);
        executor.execute(recipe, new uint256[](0), new bytes[](0));
        recipe.queries[0].offset = 0;
        vm.expectRevert(bytes("query reached"));
        executor.execute(recipe, new uint256[](0), new bytes[](0));
    }

    function testFuzz_StoredCallBindingReplacesCommittedAmount(uint256 amount) public {
        IRecipeExecutor.Recipe memory recipe = _recipe(1);
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](1);
        bindings[0] = IRecipeExecutor.Binding(4, _literal(amount));
        recipe.steps[0] = _call(address(target), abi.encodeCall(RecipeReviewTarget.record, (amount ^ 1)), bindings);
        executor.setRecipe(recipe);
        assertEq(executor.execute(recipe, new uint256[](0), new bytes[](0)).length, 1);
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

    function test_SharedQueryUsesFreshDataAndFrozenReference() public {
        IRecipeExecutor.Recipe memory recipe = _recipe(7);
        recipe.queries = new IRecipeExecutor.Query[](2);
        recipe.queries[0] = IRecipeExecutor.Query(address(target), abi.encodeWithSignature("recorded()"), _none(), 0);
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](1);
        bindings[0] = IRecipeExecutor.Binding(4, _result(0));
        recipe.queries[1] =
            IRecipeExecutor.Query(address(target), abi.encodeCall(RecipeReviewTarget.echo, (999)), bindings, 0);
        recipe.steps[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Read, abi.encode(uint256(0)));
        recipe.steps[1] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Read, abi.encode(uint256(1)));
        recipe.steps[2] = _call(address(target), abi.encodeCall(RecipeReviewTarget.record, (7)), _none());
        recipe.steps[3] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Read, abi.encode(uint256(0)));
        recipe.steps[4] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Read, abi.encode(uint256(1)));
        recipe.steps[5] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Equal, abi.encode(_result(1), _result(4)));
        recipe.steps[6] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Equal, abi.encode(_result(3), _literal(7)));
        executor.setRecipe(recipe);
        target.record(3);
        uint256[] memory values = executor.execute(recipe, new uint256[](0), new bytes[](0));
        assertEq(values[1], 3);
        assertEq(values[4], 3);
        assertEq(abi.decode(Bytes.slice(recipe.queries[1].data, 4), (uint256)), 999);
        values = executor.execute(recipe, new uint256[](0), new bytes[](0));
        assertEq(values[1], 7);
        assertEq(values[4], 7);
    }

    function test_PostconditionFailureRollsBackCallState() public {
        IRecipeExecutor.Recipe memory recipe = _recipe(3);
        recipe.queries = new IRecipeExecutor.Query[](1);
        recipe.queries[0] = IRecipeExecutor.Query(address(target), abi.encodeWithSignature("recorded()"), _none(), 0);
        recipe.steps[0] = _call(address(target), abi.encodeCall(RecipeReviewTarget.record, (2)), _none());
        recipe.steps[1] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Read, abi.encode(uint256(0)));
        recipe.steps[2] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Equal, abi.encode(_result(1), _literal(1)));
        executor.setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        executor.execute(recipe, new uint256[](0), new bytes[](0));
        assertEq(target.recorded(), 0);
        assertEq(target.caller(), address(0));
    }

    function test_OwnerCallbackCannotChangeConfigurationOrReenter() public {
        RecipeReviewOwner owner = new RecipeReviewOwner();
        executor = new RecipeExecutor(address(owner), address(1));
        IRecipeExecutor.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = _call(address(owner), abi.encodeCall(RecipeReviewOwner.probe, ()), _none());
        owner.configure(address(executor), address(this), recipe);
        executor.execute(recipe, new uint256[](0), new bytes[](0));
        assertTrue(owner.checked());
        assertEq(executor.recipeHash(), keccak256(abi.encode(recipe)));
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
        IRecipeExecutor.Recipe memory recipe = _recipe(1);
        recipe.queries = new IRecipeExecutor.Query[](1);
        recipe.queries[0] =
            IRecipeExecutor.Query(address(target), abi.encodeCall(RecipeReviewTarget.raw, (data)), _none(), offset);
        recipe.steps[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Read, abi.encode(uint256(0)));
        executor.setRecipe(recipe);
        if (!valid) vm.expectRevert();
        uint256[] memory values = executor.execute(recipe, new uint256[](0), new bytes[](0));
        if (valid) assertEq(values[0], expected);
    }

    function _recipe(uint256 length) internal pure returns (IRecipeExecutor.Recipe memory recipe) {
        recipe.queries = new IRecipeExecutor.Query[](0);
        recipe.steps = new IRecipeExecutor.Step[](length);
    }

    function _call(address recipient, bytes memory data, IRecipeExecutor.Binding[] memory bindings)
        internal
        pure
        returns (IRecipeExecutor.Step memory)
    {
        return IRecipeExecutor.Step(IRecipeExecutor.Operation.Call, abi.encode(recipient, data, bindings));
    }

    function _none() internal pure returns (IRecipeExecutor.Binding[] memory) {
        return new IRecipeExecutor.Binding[](0);
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
    bytes internal _configured;

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
        IRecipeExecutor.Recipe memory recipe;
        recipe.queries = new IRecipeExecutor.Query[](0);
        recipe.steps = new IRecipeExecutor.Step[](1);
        recipe.steps[0] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Manage,
            abi.encode(IRecipeExecutor.Value(IRecipeExecutor.Source.Literal, 1), leaves, bindings)
        );
        _configured = recipe.steps[0].data;
        RecipeExecutor(executor).setRecipe(recipe);
    }

    function _execute(bytes memory actions) internal {
        IRecipeExecutor.Recipe memory recipe;
        recipe.queries = new IRecipeExecutor.Query[](0);
        recipe.steps = new IRecipeExecutor.Step[](1);
        recipe.steps[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Manage, _configured);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = actions;
        RecipeExecutor(executor).execute(recipe, new uint256[](0), runtime);
    }
}
