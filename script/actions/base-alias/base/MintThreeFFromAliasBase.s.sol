// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../../base-chain/BaseAliasPayloads.sol";
import {ExecutingRecipe} from "../../../recipes/ExecutingRecipe.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title MintThreeFFromAliasBase
/// @notice Base script running the committed alias mint recipe on Ethereum, which sends the four mint deposits.
contract MintThreeFFromAliasBaseScript is BaseAliasActionBase {
    /// @notice Raised when the executor is not bound to the account or does not hold the recipe for `maxPrincipal`.
    error RecipeMismatch();

    /**
     * @notice Calls `RecipeExecutor.execute` with the request, principal and yield of one won 3F auction.
     * @dev The sender must be the executor's caller. The recipe sends `consume`, `approve`, `mint` and `approve(0)`
     * as four Base transactions from the alias, in order. Read `principal` and `yieldAssets` from
     * `mintAuthorization(alias)` on the request on Base. Before you run it, check `isRequest(request)` on 3F's
     * RequestFactory and simulate the four calls on Base from the alias: a failed `consume` does not stop the mint.
     * `maxPrincipal` must be the value used for the committed recipe; the script checks the recipe hash first.
     */
    function runBase(
        string memory manifest,
        string memory proofs,
        address executor,
        uint256 maxPrincipal,
        address request,
        uint256 principal,
        uint256 yieldAssets
    ) public virtual returns (bytes memory data) {
        _requireEthereum();
        BaseAliasPayloads.Deployment memory deployment = _deployment(manifest);
        ExecutingRecipe.Recipe memory recipe = BaseAliasPayloads.mintRecipe(deployment, maxPrincipal);
        if (
            IRecipeExecutor(executor).account() != deployment.ethereumAccount
                || IRecipeExecutor(executor).recipeHash() != keccak256(abi.encode(recipe.queries, recipe.steps))
        ) revert RecipeMismatch();
        IMerkleAccount.Action[] memory actions =
            BaseAliasPayloads.mintActions(deployment, request, principal, yieldAssets);
        _attachProofs(proofs, actions);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encode(actions);
        data = abi.encodeCall(
            IRecipeExecutor.execute,
            (recipe.queries, recipe.steps, BaseAliasPayloads.mintInputs(request, principal, yieldAssets), runtime)
        );
        sendTransaction(executor, data);
        Logs.logSimulationLink(executor, data);
        Logs.log(
            string.concat(
                "Mint 3F from the Base alias\n    alias:",
                vm.toString(BaseAliasPayloads.aliasOf(deployment)),
                "\n    request:",
                vm.toString(request),
                "\n    principal:",
                vm.toString(principal),
                "\n    yield:",
                vm.toString(yieldAssets)
            )
        );
    }
}
