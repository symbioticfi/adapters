// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../../base-chain/BaseAliasPayloads.sol";
import {ExecutingRecipe} from "../../../recipes/ExecutingRecipe.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title MintThreeFFromAliasBase
/// @notice Runs the committed Ethereum recipe that queues one atomic mint on Base.
contract MintThreeFFromAliasBaseScript is BaseAliasActionBase {
    /// @notice Raised when the executor is not bound to the account or does not hold the mint recipe.
    error RecipeMismatch();

    /// @notice Runs the recipe using the 3F request and the accepted offer's bounds.
    /// @dev The recipe caps the principal and binds all matching words in the AccessManager batch.
    function runBase(
        string memory manifest,
        string memory proofs,
        address executor,
        uint256 maxPrincipal,
        address request,
        uint128 principal,
        uint128 yieldAssets
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
                "\n    manager:",
                vm.toString(deployment.manager),
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
