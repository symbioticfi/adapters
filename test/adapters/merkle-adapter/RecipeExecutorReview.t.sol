// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ExecutingRecipe} from "../../../script/recipes/ExecutingRecipe.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "../../../src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {Token} from "../../mocks/Token.sol";

import {MerkleAdapterVerifier} from "../../../src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
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

    function configure(address newExecutor, address newCaller, ExecutingRecipe.Recipe calldata recipe) public {
        executor = newExecutor;
        RecipeExecutor(executor).setCaller(newCaller);
        RecipeExecutor(executor).setRecipe(recipe.queries, recipe.steps);
    }

    function probe() public {
        require(executor == msg.sender);
        ExecutingRecipe.Recipe memory empty;
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(RecipeExecutor.setRecipe, (empty.queries, empty.steps));
        calls[1] = abi.encodeCall(RecipeExecutor.setCaller, (address(0)));
        calls[2] =
            abi.encodeCall(RecipeExecutor.execute, (empty.queries, empty.steps, new uint256[](0), new bytes[](0)));
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
        ExecutingRecipe.Recipe memory recipe = _recipe(2);
        recipe.queries = new bytes[](1);
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](1);
        bindings[0] = IRecipeExecutor.Binding({offset: amount, value: _literal(amount)});
        recipe.queries[0] = abi.encode(address(target), data, bindings, amount);
        recipe.steps[0] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation(operation % (uint8(IRecipeExecutor.Operation.Call) + 1)), data: data
        });
        recipe.steps[1] = _call(address(target), abi.encodeCall(RecipeReviewTarget.record, (amount)), _none());
        vm.recordLogs();
        executor.setRecipe(recipe.queries, recipe.steps);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(executor));
        assertEq(logs[0].topics[1], keccak256(abi.encode(recipe.queries, recipe.steps)));
        assertEq(logs[0].data, abi.encode(recipe.queries, recipe.steps));
        assertEq(executor.recipeHash(), keccak256(abi.encode(recipe.queries, recipe.steps)));
        assertEq(executor.recipeBlock(), block.number);
        recipe.steps[0].data = bytes.concat(data, hex"01");
        vm.expectRevert(IRecipeExecutor.InvalidRecipe.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe = _recipe(0);
        executor.setRecipe(recipe.queries, recipe.steps);
        assertEq(executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0)).length, 0);
    }

    function test_ConfigurationUsesTwoSlotsIndependentOfRecipeSize() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(300);
        recipe.queries = new bytes[](30);
        for (uint256 i; i < recipe.steps.length; ++i) {
            recipe.steps[i] = IRecipeExecutor.Step({
                operation: IRecipeExecutor.Operation.Add, data: abi.encode(_literal(i), _literal(1))
            });
        }
        for (uint256 i; i < recipe.queries.length; ++i) {
            recipe.queries[i] = abi.encode(address(target), new bytes(1000), _none(), i);
        }
        vm.record();
        executor.setRecipe(recipe.queries, recipe.steps);
        (, bytes32[] memory writes) = vm.accesses(address(executor));
        assertEq(writes.length, 2);
        assertEq(vm.load(address(executor), bytes32(uint256(2))), keccak256(abi.encode(recipe.queries, recipe.steps)));
        assertEq(uint256(vm.load(address(executor), bytes32(uint256(3)))), block.number);
        uint256[] memory values = executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(values.length, 300);
        assertEq(values[299], 300);
        recipe = _recipe(0);
        vm.roll(block.number + 1);
        vm.record();
        executor.setRecipe(recipe.queries, recipe.steps);
        (, writes) = vm.accesses(address(executor));
        assertEq(writes.length, 2);
        assertEq(executor.recipeBlock(), block.number);
    }

    function test_RejectsUnconfiguredChangedRecipeAndWrongCallerBeforeQueries() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.queries = new bytes[](1);
        recipe.queries[0] = abi.encode(address(target), abi.encodeCall(RecipeReviewTarget.rejectRead, ()), _none(), 0);
        recipe.steps[0] =
            IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.Read, data: abi.encode(uint256(0))});
        vm.expectRevert(IRecipeExecutor.InvalidRecipe.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.prank(address(123));
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe.queries[0] =
            abi.encode(address(target), abi.encodeCall(RecipeReviewTarget.rejectRead, ()), _none(), uint256(32));
        vm.expectRevert(IRecipeExecutor.InvalidRecipe.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        recipe.queries[0] =
            abi.encode(address(target), abi.encodeCall(RecipeReviewTarget.rejectRead, ()), _none(), uint256(0));
        vm.expectRevert(bytes("query reached"));
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
    }

    function testFuzz_StoredCallBindingReplacesCommittedAmount(uint256 amount) public {
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](1);
        bindings[0] = IRecipeExecutor.Binding({offset: 4, value: _literal(amount)});
        recipe.steps[0] = _call(address(target), abi.encodeCall(RecipeReviewTarget.record, (amount ^ 1)), bindings);
        executor.setRecipe(recipe.queries, recipe.steps);
        assertEq(executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0)).length, 1);
        assertEq(target.recorded(), amount);
        assertEq(target.caller(), address(executor));
    }

    function testFuzz_TruncatedQueryTupleRollsBackEarlierCalls(uint8 length) public {
        ExecutingRecipe.Recipe memory recipe = _recipe(2);
        recipe.queries = new bytes[](1);
        recipe.queries[0] = Bytes.slice(
            abi.encode(address(target), abi.encodeWithSignature("recorded()"), _none(), uint256(0)),
            0,
            uint256(length) % 128
        );
        recipe.steps[0] = _call(address(target), abi.encodeCall(RecipeReviewTarget.record, (7)), _none());
        recipe.steps[1] =
            IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.Read, data: abi.encode(uint256(0))});
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(target.recorded(), 0);
    }

    function test_QueryTupleRejectsInvalidDynamicOffsetsAndOuterStructEncoding() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.queries = new bytes[](1);
        recipe.steps[0] =
            IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.Read, data: abi.encode(uint256(0))});
        bytes memory query = abi.encode(address(target), abi.encodeWithSignature("recorded()"), _none(), uint256(0));
        for (uint256 offset = 32; offset <= 64; offset += 32) {
            recipe.queries[0] = bytes.concat(query);
            Bytes.replace(recipe.queries[0], offset, abi.encode(type(uint256).max));
            executor.setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert();
            executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        }
        recipe.queries[0] = bytes.concat(abi.encode(uint256(32)), query);
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert();
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
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
        ExecutingRecipe.Recipe memory recipe = _recipe(7);
        recipe.queries = new bytes[](2);
        recipe.queries[0] = abi.encode(address(target), abi.encodeWithSignature("recorded()"), _none(), 0);
        IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](1);
        bindings[0] = IRecipeExecutor.Binding({offset: 4, value: _result(0)});
        recipe.queries[1] = abi.encode(address(target), abi.encodeCall(RecipeReviewTarget.echo, (999)), bindings, 0);
        recipe.steps[0] =
            IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.Read, data: abi.encode(uint256(0))});
        recipe.steps[1] =
            IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.Read, data: abi.encode(uint256(1))});
        recipe.steps[2] = _call(address(target), abi.encodeCall(RecipeReviewTarget.record, (7)), _none());
        recipe.steps[3] =
            IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.Read, data: abi.encode(uint256(0))});
        recipe.steps[4] =
            IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.Read, data: abi.encode(uint256(1))});
        recipe.steps[5] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Equal, data: abi.encode(_result(1), _result(4))
        });
        recipe.steps[6] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Equal, data: abi.encode(_result(3), _literal(7))
        });
        executor.setRecipe(recipe.queries, recipe.steps);
        target.record(3);
        uint256[] memory values = executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(values[1], 3);
        assertEq(values[4], 3);
        (, bytes memory template,,) =
            abi.decode(recipe.queries[1], (address, bytes, IRecipeExecutor.Binding[], uint256));
        assertEq(abi.decode(Bytes.slice(template, 4), (uint256)), 999);
        values = executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(values[1], 7);
        assertEq(values[4], 7);
    }

    function test_PostconditionFailureRollsBackCallState() public {
        ExecutingRecipe.Recipe memory recipe = _recipe(3);
        recipe.queries = new bytes[](1);
        recipe.queries[0] = abi.encode(address(target), abi.encodeWithSignature("recorded()"), _none(), 0);
        recipe.steps[0] = _call(address(target), abi.encodeCall(RecipeReviewTarget.record, (2)), _none());
        recipe.steps[1] =
            IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.Read, data: abi.encode(uint256(0))});
        recipe.steps[2] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Equal, data: abi.encode(_result(1), _literal(1))
        });
        executor.setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(target.recorded(), 0);
        assertEq(target.caller(), address(0));
    }

    function test_OwnerCallbackCannotChangeConfigurationOrReenter() public {
        RecipeReviewOwner owner = new RecipeReviewOwner();
        executor = new RecipeExecutor(address(owner), address(1));
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.steps[0] = _call(address(owner), abi.encodeCall(RecipeReviewOwner.probe, ()), _none());
        owner.configure(address(executor), address(this), recipe);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertTrue(owner.checked());
        assertEq(executor.recipeHash(), keccak256(abi.encode(recipe.queries, recipe.steps)));
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
        ExecutingRecipe.Recipe memory recipe = _recipe(1);
        recipe.queries = new bytes[](1);
        recipe.queries[0] = abi.encode(address(target), abi.encodeCall(RecipeReviewTarget.raw, (data)), _none(), offset);
        recipe.steps[0] =
            IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.Read, data: abi.encode(uint256(0))});
        executor.setRecipe(recipe.queries, recipe.steps);
        if (!valid) vm.expectRevert();
        uint256[] memory values = executor.execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        if (valid) assertEq(values[0], expected);
    }

    function _recipe(uint256 length) internal pure returns (ExecutingRecipe.Recipe memory recipe) {
        recipe.queries = new bytes[](0);
        recipe.steps = new IRecipeExecutor.Step[](length);
    }

    function _call(address recipient, bytes memory data, IRecipeExecutor.Binding[] memory bindings)
        internal
        pure
        returns (IRecipeExecutor.Step memory)
    {
        return IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Call, data: abi.encode(recipient, data, bindings)
        });
    }

    function _none() internal pure returns (IRecipeExecutor.Binding[] memory) {
        return new IRecipeExecutor.Binding[](0);
    }

    function _literal(uint256 value) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value({source: IRecipeExecutor.Source.Literal, value: value});
    }

    function _result(uint256 index) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value({source: IRecipeExecutor.Source.Result, value: index});
    }
}

contract RecipeExecutorEncodingTest is CapabilityTestBase {
    address internal executor;
    address internal target;
    bytes internal _configured;

    function setUp() public {
        _deployAdapter(address(new Token("Asset")));
        executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(executor).setCaller(address(this));
        target = address(new RecipeReviewTarget());
    }

    function test_ManageTrailingBytesDoNotChangeAuthorization() public {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _action(target, 7);
        bytes32[] memory leaves = _publish(actions);
        _configure(leaves, new IRecipeExecutor.Binding[][](1));
        _execute(bytes.concat(abi.encode(actions), hex"deadbeef"));
        assertEq(RecipeReviewTarget(target).recorded(), 7);
        assertEq(RecipeReviewTarget(target).caller(), account);

        actions[0].data = abi.encodeCall(RecipeReviewTarget.record, (8));
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(bytes.concat(abi.encode(actions), hex"deadbeef"));
        assertEq(RecipeReviewTarget(target).recorded(), 7);
    }

    function testFuzz_ManageRelocatedTailChecksFinalBoundLeaf(uint128 amount) public {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _action(target, amount);
        bytes32[] memory leaves = _publish(actions);
        IRecipeExecutor.Binding[][] memory bindings = _bindings(amount, 1);
        _configure(leaves, bindings);
        actions[0].data = abi.encodeCall(RecipeReviewTarget.record, (0));
        bytes memory canonical = abi.encode(actions);
        bytes memory relocated = bytes.concat(canonical, Bytes.slice(abi.encode(actions[0].data), 32));
        Bytes.replace(relocated, 160, abi.encode(canonical.length - 96));
        assertEq(abi.encode(abi.decode(relocated, (IMerkleAccount.Action[]))), canonical);

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
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
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
        assertEq(abi.encode(abi.decode(shared, (IMerkleAccount.Action[]))), canonical);

        _execute(shared);
        assertEq(RecipeReviewTarget(target).recorded(), 7);
        assertEq(RecipeReviewTarget(second).recorded(), 9);
        assertEq(RecipeReviewTarget(target).caller(), account);
        assertEq(RecipeReviewTarget(second).caller(), account);
    }

    function test_ManageSharedDataAndMaskTailPreservesCommittedMask() public {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _action(target, 7);
        actions[0].dataMask = abi.encodeCall(RecipeReviewTarget.record, (0));
        bytes32[] memory leaves = _publish(actions);
        _configure(leaves, _bindings(7, 1));
        actions[0].data = actions[0].dataMask;
        bytes memory canonical = abi.encode(actions);
        bytes memory shared = bytes.concat(canonical, Bytes.slice(abi.encode(actions[0].data), 32));
        Bytes.replace(shared, 160, abi.encode(canonical.length - 96));
        Bytes.replace(shared, 192, abi.encode(canonical.length - 96));
        assertEq(abi.encode(abi.decode(shared, (IMerkleAccount.Action[]))), canonical);

        _execute(shared);
        assertEq(RecipeReviewTarget(target).recorded(), 7);
        assertEq(RecipeReviewTarget(target).caller(), account);
    }

    function _action(address recipient, uint256 amount) internal pure returns (IMerkleAccount.Action memory) {
        bytes memory data = abi.encodeCall(RecipeReviewTarget.record, (amount));
        return IMerkleAccount.Action({
            target: recipient, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
    }

    function _publish(IMerkleAccount.Action[] memory actions) internal returns (bytes32[] memory leaves) {
        leaves = new bytes32[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            leaves[i] = MerkleAdapterVerifier.leaf(actions[i].target, 0, actions[i].data, actions[i].dataMask);
            MerkleAccount(payable(account)).grantRole(leaves[i], executor);
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
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
    }

    function _bindings(uint256 amount, uint256 length)
        internal
        pure
        returns (IRecipeExecutor.Binding[][] memory bindings)
    {
        bindings = new IRecipeExecutor.Binding[][](length);
        for (uint256 i; i < length; ++i) {
            bindings[i] = new IRecipeExecutor.Binding[](1);
            bindings[i][0] = IRecipeExecutor.Binding({
                offset: 4, value: IRecipeExecutor.Value({source: IRecipeExecutor.Source.Literal, value: amount})
            });
        }
    }

    function _configure(bytes32[] memory leaves, IRecipeExecutor.Binding[][] memory bindings) internal {
        ExecutingRecipe.Recipe memory recipe;
        recipe.queries = new bytes[](0);
        recipe.steps = new IRecipeExecutor.Step[](1);
        recipe.steps[0] = IRecipeExecutor.Step({
            operation: IRecipeExecutor.Operation.Manage,
            data: abi.encode(
                IRecipeExecutor.Value({source: IRecipeExecutor.Source.Literal, value: 1}), leaves, bindings
            )
        });
        _configured = recipe.steps[0].data;
        RecipeExecutor(executor).setRecipe(recipe.queries, recipe.steps);
    }

    function _execute(bytes memory actions) internal {
        ExecutingRecipe.Recipe memory recipe;
        recipe.queries = new bytes[](0);
        recipe.steps = new IRecipeExecutor.Step[](1);
        recipe.steps[0] = IRecipeExecutor.Step({operation: IRecipeExecutor.Operation.Manage, data: _configured});
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = actions;
        RecipeExecutor(executor).execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
    }
}
