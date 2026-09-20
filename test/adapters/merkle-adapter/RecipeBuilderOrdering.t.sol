// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {Test} from "forge-std/Test.sol";

contract RecipeBuilderOrderingTest is Test {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    function test_ObservationsCannotReorderAllocatedResults() public {
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.misorderedObservation(true);
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.misorderedObservation(false);
    }

    function test_AfterCalculationsCannotOvertakeNextActionCalculations() public {
        vm.expectRevert(ExecutingRecipe.InvalidConfiguration.selector);
        this.misorderedAfterCalculation();
    }

    function misorderedObservation(bool pending) public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(4);
        builder.manage(new bytes32[](0), builder.literal(0));
        if (pending) builder.binary(IRecipeExecutor.Operation.Add, builder.literal(1), builder.literal(2));
        else builder.afterBinary(IRecipeExecutor.Operation.Add, builder.literal(1), builder.literal(2));
        builder.observe(
            ExecutingRecipe.query(ExecutingRecipe.Read(address(1), hex"12345678", 0)),
            IRecipeExecutor.ObservationKind.After
        );
    }

    function misorderedAfterCalculation() public pure {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(4);
        builder.manage(new bytes32[](0), builder.literal(0));
        builder.binary(IRecipeExecutor.Operation.Add, builder.literal(1), builder.literal(2));
        builder.afterBinary(IRecipeExecutor.Operation.Add, builder.literal(3), builder.literal(4));
    }
}
