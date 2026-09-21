// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";
import {ThreeFGuardedMint} from "./ThreeFGuardedMint.sol";

import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";

/**
 * @title ThreeFExecuting
 * @notice Library for native 3F funding and minting entirely through RecipeExecutor.
 * @dev Create ThreeFPolicy through its MigratablesFactory with the account as its sole consumer, and
 * let its owner configure the asset's yield minimum and period budget. The charge originates from
 * the account: `mintLeaf` is the guarded leaf from ThreeFGuardedMint, which calls `policy.consume`
 * beside the mint and binds both declared amounts to the observed principal, yield and cash movements. The recipe
 * therefore supplies the live authorization and omits conditions the leaf already enforces. Build the
 * leaf from the same Config, or its committed mask will not match these binding offsets.
 */
library ThreeFExecuting {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    struct Config {
        ExecutingRecipe.Funding funding;
        address request;
        address requestsFactory;
        address policy;
        bytes32 approvalLeaf;
        bytes32 mintLeaf;
        uint256 maxPrincipal;
    }

    // Calls and approvals index runtime payloads; numeric Values index instructions.
    struct Layout {
        uint256[] sourceCalls;
        uint256[] sourceAmounts;
        IRecipeExecutor.Value principal;
        IRecipeExecutor.Value authorizedYield;
        uint256 approve;
        uint256 operation;
        uint256 clearApproval;
    }

    function build(Config memory config)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(24 + config.funding.sources.length);
        ExecutingRecipe.Read memory authorization = ExecutingRecipe.Read({
            target: config.request,
            data: abi.encodeCall(IThreeFPushRequest.mintAuthorization, (config.funding.account)),
            offset: 0
        });
        layout.principal = builder.read(authorization);
        authorization.offset = 32;
        layout.authorizedYield = builder.read(authorization);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, builder.literal(1), layout.principal);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, layout.principal, builder.literal(config.maxPrincipal));
        (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, layout.principal);
        layout.approve = builder.approve(config.funding.asset, config.request, config.approvalLeaf, layout.principal);
        builder.check(IRecipeExecutor.Operation.Equal, layout.authorizedYield, builder.read(authorization));
        authorization.offset = 0;
        builder.check(IRecipeExecutor.Operation.Equal, layout.principal, builder.read(authorization));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = config.mintLeaf;
        layout.operation = builder.manage(leaves, layout.principal, _bindings(config, layout));
        layout.clearApproval =
            builder.approve(config.funding.asset, config.request, config.approvalLeaf, builder.literal(0));
        recipe = builder.finish();
    }

    /// @dev Feeds the live authorization into the guarded leaf's four variable words, in ascending order.
    function _bindings(Config memory config, Layout memory layout)
        private
        pure
        returns (IRecipeExecutor.Binding[][] memory bindings)
    {
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({
                account: config.funding.account,
                asset: config.funding.asset,
                policy: config.policy,
                request: config.request,
                requestsFactory: config.requestsFactory
            })
        );
        bindings = new IRecipeExecutor.Binding[][](1);
        bindings[0] = new IRecipeExecutor.Binding[](4);
        bindings[0][0] = IRecipeExecutor.Binding({offset: leaf.consumeAssets, value: layout.principal});
        bindings[0][1] = IRecipeExecutor.Binding({offset: leaf.consumeYield, value: layout.authorizedYield});
        bindings[0][2] = IRecipeExecutor.Binding({offset: leaf.mintPrincipal, value: layout.principal});
        bindings[0][3] = IRecipeExecutor.Binding({offset: leaf.mintYield, value: layout.authorizedYield});
    }
}
