// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {OP_APPROVE, OP_MANAGE} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract RecipeRepayBuildTest is Test {
    using stdJson for string;

    function test_HealthRepayExampleHasNoRequestsOrClaims() public {
        vm.mockCall(address(0x103), abi.encodeCall(IMerkleAdapter.account, ()), abi.encode(address(0x104)));
        address builder = deployCode("BuildRecipe.s.sol:BuildRecipe");
        string memory outputPath = "out/RecipeRepayBuild.health-repay.json";
        BuildRecipe(builder).run("script/recipes/examples/health-repay.json", outputPath);
        string memory output = vm.readFile(outputPath);
        ExecutingRecipe.Recipe memory recipe;
        (recipe.queries, recipe.steps) = abi.decode(output.readBytes(".recipe"), (bytes[], bytes[]));
        assertEq(output.readBytes32(".recipeHash"), keccak256(abi.encode(recipe.queries, recipe.steps)));
        assertEq(output.readAddress(".account"), address(0x104));
        assertEq(output.readUintArray(".sourceCalls").length, 0);
        assertEq(output.readUintArray(".requestCalls").length, 0);
        assertEq(output.readUintArray(".claimCalls").length, 0);
        uint256[] memory runtimeSteps = ExecutingRecipe.runtimeSteps(recipe);
        assertEq(runtimeSteps.length, 3);
        assertEq(uint8(recipe.steps[runtimeSteps[output.readUint(".approveStep")]][0]), OP_APPROVE);
        assertEq(uint8(recipe.steps[runtimeSteps[output.readUint(".repayStep")]][0]), OP_MANAGE);
        assertEq(uint8(recipe.steps[runtimeSteps[output.readUint(".clearApprovalStep")]][0]), OP_APPROVE);
        vm.removeFile(outputPath);
    }
}
