// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {Test} from "forge-std/Test.sol";

contract RecipeBuilderOrderingTest is Test {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    function test_ReadsAndCalculationsKeepInstructionOrderAcrossActions() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        IRecipeExecutor.Query memory query = ExecutingRecipe.query(ExecutingRecipe.Read(address(1), hex"12345678", 0));
        IRecipeExecutor.Value memory before = builder.readQuery(query);
        uint256 runtime = builder.manage(new bytes32[](0), builder.literal(0));
        IRecipeExecutor.Value memory afterValue = builder.readQuery(query);
        IRecipeExecutor.Value memory delta = builder.binary(IRecipeExecutor.Operation.Subtract, afterValue, before);
        builder.check(IRecipeExecutor.Operation.Equal, delta, builder.literal(0));
        IRecipeExecutor.Recipe memory recipe = builder.finish();
        assertEq(before.value, 0);
        assertEq(runtime, 0);
        assertEq(afterValue.value, 2);
        assertEq(delta.value, 3);
        assertEq(recipe.steps.length, 5);
        assertEq(recipe.queries.length, 1);
        assertEq(recipe.steps[0].data, recipe.steps[2].data);
        assertEq(ExecutingRecipe.runtimeSteps(recipe)[0], 1);
    }

    function test_SharedQueriesCommitBindingsAndReturnOffsets() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        IRecipeExecutor.Query memory query = ExecutingRecipe.query(
            ExecutingRecipe.Read(address(1), abi.encodeWithSelector(bytes4(0x12345678), uint256(0)), 0)
        );
        query.bindings = new IRecipeExecutor.Binding[](1);
        query.bindings[0] = IRecipeExecutor.Binding(4, builder.input(0));
        builder.readQuery(query);
        query.bindings[0].value = builder.input(1);
        builder.readQuery(query);
        query.offset = 1;
        builder.readQuery(query);
        IRecipeExecutor.Recipe memory recipe = builder.finish();
        assertEq(recipe.queries.length, 3);
        assertEq(recipe.queries[0].bindings[0].value.value, 0);
        assertEq(recipe.queries[1].bindings[0].value.value, 1);
        assertEq(recipe.queries[2].offset, 1);
    }

    function test_ManageBindingsMustMatchLeaves() public {
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.invalidBindings();
    }

    function invalidBindings() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        builder.manage(new bytes32[](1), builder.literal(1), new IRecipeExecutor.Binding[][](0));
    }
}
