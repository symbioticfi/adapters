// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./base/BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../base-chain/BaseAliasPayloads.sol";
import {ExecutingRecipe} from "../../recipes/ExecutingRecipe.sol";
import {RecipeManifest} from "../../recipes/RecipeManifest.sol";

import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {Logs} from "../../utils/Logs.sol";

/**
 * @title BuildBaseAliasMintRecipe
 * @notice Script writing the `RecipeExecutor` recipe and the owner transactions for the alias 3F mint.
 * @dev Builds the recipe from `BaseAliasPayloads.mintRecipe`, then writes the recipe, its hash, the four mint
 * leaves, the executor constructor arguments and the calldata for `ImmutableFactory.create`, `setRecipe` and
 * `setCaller`. Sends nothing: the executor owner sends `setRecipe` and `setCaller`, and the MerkleAccount root must
 * grant the four mint leaf roles to the executor. The executor owner can replace the recipe and the caller
 * without a new root, so the owner is as trusted as the root for the mint leaves.
 */
contract BuildBaseAliasMintRecipeScript is BaseAliasActionBase {
    /// @dev Symbiotic's RecipeExecutor ImmutableFactory on Ethereum, from `script/deploy/merkle/mainnet.json`.
    address internal constant RECIPE_EXECUTOR_FACTORY = 0x74aF05cc780B9B9820B0e8Ce9047D12747725FF6;

    /// @notice Raised when the recipe path already exists or an address in the environment is zero.
    error InvalidOutput();

    /**
     * @notice Writes the alias mint recipe and the transactions that install it.
     * @dev Reads BASE_ALIAS_MANIFEST, BASE_ALIAS_MAX_PRINCIPAL (largest principal for one mint, USDC base units),
     * BASE_ALIAS_RECIPE_OWNER, BASE_ALIAS_RECIPE_CALLER (the mint bot) and BASE_ALIAS_RECIPE (output path).
     * Refuses to overwrite the output.
     */
    function run() public returns (bytes32 recipeHash) {
        string memory path = vm.envString("BASE_ALIAS_RECIPE");
        address owner = vm.envAddress("BASE_ALIAS_RECIPE_OWNER");
        address caller = vm.envAddress("BASE_ALIAS_RECIPE_CALLER");
        if (vm.exists(path) || owner == address(0) || caller == address(0)) revert InvalidOutput();
        uint256 maxPrincipal = vm.envUint("BASE_ALIAS_MAX_PRINCIPAL");
        BaseAliasPayloads.Deployment memory deployment = _deployment(vm.envString("BASE_ALIAS_MANIFEST"));
        ExecutingRecipe.Recipe memory recipe = BaseAliasPayloads.mintRecipe(deployment, maxPrincipal);
        recipeHash = keccak256(abi.encode(recipe.queries, recipe.steps));
        bytes memory constructorArgs = abi.encode(owner, deployment.ethereumAccount);

        vm.serializeAddress("recipe", "account", deployment.ethereumAccount);
        vm.serializeAddress("recipe", "alias", BaseAliasPayloads.aliasOf(deployment));
        vm.serializeAddress("recipe", "owner", owner);
        vm.serializeAddress("recipe", "caller", caller);
        vm.serializeUint("recipe", "maxPrincipal", maxPrincipal);
        vm.serializeBytes32("recipe", "mintLeaves", BaseAliasPayloads.mintLeaves(deployment));
        vm.serializeBytes("recipe", "recipe", abi.encode(recipe.queries, recipe.steps));
        vm.serializeBytes32("recipe", "recipeHash", recipeHash);
        vm.serializeAddress("recipe", "factory", RECIPE_EXECUTOR_FACTORY);
        vm.serializeBytes("recipe", "constructorArgs", constructorArgs);
        vm.serializeBytes(
            "recipe", "factoryCreateCalldata", abi.encodeCall(IImmutableFactory.create, (constructorArgs))
        );
        vm.serializeBytes(
            "recipe", "setRecipeCalldata", abi.encodeCall(IRecipeExecutor.setRecipe, (recipe.queries, recipe.steps))
        );
        vm.writeJson(
            vm.serializeBytes("recipe", "setCallerCalldata", abi.encodeCall(IRecipeExecutor.setCaller, (caller))), path
        );
        vm.writeJson(RecipeManifest.render(recipe), path, ".manifest");
        Logs.log(string.concat("Alias mint recipe hash: ", vm.toString(recipeHash)));
    }
}
