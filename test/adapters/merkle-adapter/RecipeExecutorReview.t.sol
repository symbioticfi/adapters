// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {RecipeExecutor} from "../../../src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {IRecipeExecutor} from "../../../src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

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
