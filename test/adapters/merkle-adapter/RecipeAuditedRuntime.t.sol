// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Token} from "test/mocks/Token.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {IRecipes, OP_READ, OP_CALL, OP_EQUAL} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";

contract RecipeAuditedRuntimeTest is CapabilityTestBase {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    address internal _executor;
    uint256 public stored;

    function setUp() public {
        _deployAdapter(address(new Token("Audited runtime")));
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
    }

    function testFuzz_RetiredOperationsRejectInBothContexts(uint8 selector, bool capability) public {
        uint8[6] memory operations = [uint8(12), uint8(13), uint8(14), uint8(15), uint8(16), uint8(17)];
        ExecutingRecipe.Recipe memory recipe;
        recipe.queries = new bytes[](0);
        recipe.steps = new bytes[](1);
        recipe.steps[0] = abi.encodePacked(operations[selector % 6], abi.encode(uint256(0)));
        // The account's self-call is authorized before the interpreter is reached.
        if (capability) {
            IMerkleAccount.Action[] memory actions = _publishCall(
                account, abi.encodeCall(IRecipeCapability.execute, (recipe.queries, recipe.steps, new uint256[](0)))
            );
            vm.expectRevert(IRecipes.InvalidOperation.selector);
            IMerkleAccount(account).manage(actions);
        } else {
            RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(IRecipes.InvalidOperation.selector);
            RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        }
    }

    function testFuzz_SelectionRetainsFullWidthValues(uint256 gate, uint256 value, uint256 fallbackValue) public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 selected = builder.readIf(
            ExecutingRecipe.query(
                ExecutingRecipe.Read({target: address(this), data: abi.encodeCall(this.echo, (value)), offset: 0})
            ),
            builder.input(0),
            builder.input(1)
        );
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = gate;
        inputs[1] = fallbackValue;
        uint256[] memory values = _run(builder.finish(), inputs);
        assertEq(values[uint216(selected)], gate > 0 ? value : fallbackValue);
    }

    function test_TupleReadObservesInterveningCall() public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        ExecutingRecipe.Read memory query =
            ExecutingRecipe.Read({target: address(this), data: abi.encodeCall(this.tuple, ()), offset: 0});
        uint256 beforeValue = builder.read(query);
        builder.call(address(this), abi.encodeCall(this.set, (7)), new uint256[](0));
        query.offset = 32;
        uint256 afterValue = builder.read(query);
        uint256[] memory values = _run(builder.finish(), new uint256[](0));
        assertEq(values[uint216(beforeValue)], 0);
        assertEq(values[uint216(afterValue)], 7);
    }

    function test_QueryFailureIsNotSkippedByZeroGate() public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        builder.readIf(
            ExecutingRecipe.query(
                ExecutingRecipe.Read({target: address(this), data: abi.encodeCall(this.reject, ()), offset: 0})
            ),
            builder.input(0),
            0
        );
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](1), new bytes[](0));
    }

    function test_CallAndLaterFailureRollBack() public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        builder.call(address(this), abi.encodeCall(this.set, (7)), new uint256[](0));
        builder.check(OP_EQUAL, 1, 2);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        assertEq(stored, 0);
    }

    function echo(uint256 value) public pure returns (uint256) {
        return value;
    }

    function tuple() public view returns (uint256, uint256) {
        return (stored, stored);
    }

    function set(uint256 value) public {
        stored = value;
    }

    function reject() public pure returns (uint256) {
        revert IRecipes.CheckFailed();
    }

    function _run(ExecutingRecipe.Recipe memory recipe, uint256[] memory inputs) internal returns (uint256[] memory) {
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        return RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, inputs, new bytes[](0));
    }
}
