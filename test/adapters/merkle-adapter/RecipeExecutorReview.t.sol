// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {RecipeExecutor} from "../../../src/contracts/periphery/RecipeExecutor.sol";

import {IRecipeExecutor} from "../../../src/interfaces/periphery/IRecipeExecutor.sol";

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Test} from "forge-std/Test.sol";

contract RecipeReviewTarget {
    uint256 public recorded;
    address public caller;

    function record(uint256 amount) public {
        recorded = amount;
        caller = msg.sender;
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

    function testFuzz_CommitmentCoversEveryStepField(uint256 original, uint8 field, bytes memory data) public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, original, 0, 0, data);
        executor.setRecipe(recipe);
        field %= 5;
        if (field == 0) recipe[0].operation = IRecipeExecutor.Operation.Input;
        else if (field == 1) recipe[0].a = original ^ 1;
        else if (field == 2) recipe[0].b = 1;
        else if (field == 3) recipe[0].c = 1;
        else recipe[0].data = bytes.concat(data, hex"00");

        vm.expectRevert(IRecipeExecutor.InvalidRecipe.selector);
        executor.execute(recipe, new uint256[](0), new bytes[](1));
    }

    function testFuzz_StaticArgumentBindingRejectsChangedAmount(uint256 amount) public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](4);
        recipe[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, amount, 0, 0, "");
        recipe[1] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Calldata, 3, 4, 0, "");
        recipe[2] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Equal, 0, 1, 0, "");
        recipe[3] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Invoke, 0, 0, 0, abi.encode(address(target), RecipeReviewTarget.record.selector)
        );
        executor.setRecipe(recipe);
        bytes[] memory runtime = new bytes[](4);
        runtime[3] = abi.encodeCall(RecipeReviewTarget.record, (amount));
        executor.execute(recipe, new uint256[](0), runtime);
        assertEq(target.recorded(), amount);
        assertEq(target.caller(), address(executor));

        runtime[3] = abi.encodeCall(RecipeReviewTarget.record, (amount ^ 1));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        executor.execute(recipe, new uint256[](0), runtime);
        assertEq(target.recorded(), amount);
    }

    function test_PostconditionFailureRollsBackInvokedState() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](4);
        recipe[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, 1, 0, 0, "");
        recipe[1] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Invoke, 0, 0, 0, abi.encode(address(target), RecipeReviewTarget.record.selector)
        );
        recipe[2] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Read, 0, 0, 0, abi.encode(address(target), abi.encodeWithSignature("recorded()"))
        );
        recipe[3] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Equal, 0, 2, 0, "");
        executor.setRecipe(recipe);
        bytes[] memory runtime = new bytes[](4);
        runtime[1] = abi.encodeCall(RecipeReviewTarget.record, (2));

        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        executor.execute(recipe, new uint256[](0), runtime);
        assertEq(target.recorded(), 0);
        assertEq(target.caller(), address(0));
    }

    function test_OwnerCallbackCannotChangeConfigurationOrReenter() public {
        RecipeReviewOwner owner = new RecipeReviewOwner();
        executor = new RecipeExecutor(address(owner), address(1));
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Invoke, 0, 0, 0, abi.encode(address(owner), RecipeReviewOwner.probe.selector)
        );
        owner.configure(address(executor), address(this), recipe);
        bytes32 originalHash = executor.recipeHash();
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encodeCall(RecipeReviewOwner.probe, ());
        executor.execute(recipe, new uint256[](0), runtime);

        assertTrue(owner.checked());
        assertEq(executor.recipeHash(), originalHash);
        assertEq(executor.caller(), address(this));
    }
}
