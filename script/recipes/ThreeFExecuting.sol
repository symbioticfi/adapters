// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";

/**
 * @title ThreeFExecuting
 * @notice Library for native 3F funding and minting entirely through RecipeExecutor.
 * @dev Bind a ThreeFPolicy to this RecipeExecutor and let its owner configure yield and period budget.
 * The recipe inserts live principal/yield into policy.consume; runtime supplies calldata templates and current proofs. It binds
 * those two static arguments to the native authorization, checks factory membership, and verifies
 * exact cash and PT/YT deltas. Claims do not replenish the cumulative funding budget.
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

    struct Layout {
        uint256[] sourceCalls;
        uint256[] sourceAmounts;
        IRecipeExecutor.Value principal;
        IRecipeExecutor.Value authorizedYield;
        uint256 consume;
        uint256 approve;
        uint256 operation;
        uint256 clearApproval;
    }

    function build(Config memory config)
        internal
        pure
        returns (IRecipeExecutor.Step[] memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(32 + config.funding.sources.length);
        builder.check(
            IRecipeExecutor.Comparison.Equal,
            builder.read(
                ExecutingRecipe.Read(
                    config.requestsFactory, abi.encodeCall(IThreeFRequestFactory.isRequest, (config.request)), 0
                )
            ),
            builder.literal(1)
        );
        ExecutingRecipe.Read memory authorization = ExecutingRecipe.Read(
            config.request, abi.encodeCall(IThreeFPushRequest.mintAuthorization, (config.funding.adapter)), 0
        );
        layout.principal = builder.read(authorization);
        authorization.offset = 32;
        layout.authorizedYield = builder.read(authorization);
        builder.check(IRecipeExecutor.Comparison.LessOrEqual, builder.literal(1), layout.principal);
        builder.check(IRecipeExecutor.Comparison.LessOrEqual, layout.principal, builder.literal(config.maxPrincipal));
        {
            IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](2);
            bindings[0] = IRecipeExecutor.Binding(4, layout.principal);
            bindings[1] = IRecipeExecutor.Binding(36, layout.authorizedYield);
            layout.consume = builder.action(
                IRecipeExecutor.Kind.Invoke,
                builder.literal(0),
                abi.encode(config.policy, IThreeFPolicy.consume.selector, bindings)
            );
        }
        (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, layout.principal);
        layout.approve = builder.approve(config.funding.asset, config.request, config.approvalLeaf, layout.principal);
        builder.check(IRecipeExecutor.Comparison.Equal, layout.authorizedYield, builder.read(authorization));
        authorization.offset = 0;
        builder.check(IRecipeExecutor.Comparison.Equal, layout.principal, builder.read(authorization));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = config.mintLeaf;
        layout.operation = builder.manage(leaves, layout.principal);
        builder.checkAfter(
            IRecipeExecutor.Comparison.Equal,
            builder.observe(
                ExecutingRecipe.balanceQuery(config.funding.asset, config.funding.adapter),
                IRecipeExecutor.ObservationKind.Decrease
            ),
            layout.principal
        );
        ExecutingRecipe.Read memory shares = ExecutingRecipe.Read(
            config.request, abi.encodeCall(IThreeFVaultController.balancesOf, (config.funding.adapter)), 0
        );
        builder.checkAfter(
            IRecipeExecutor.Comparison.Equal,
            builder.observe(ExecutingRecipe.query(shares), IRecipeExecutor.ObservationKind.Increase),
            layout.principal
        );
        shares.offset = 32;
        builder.checkAfter(
            IRecipeExecutor.Comparison.Equal,
            builder.observe(ExecutingRecipe.query(shares), IRecipeExecutor.ObservationKind.Increase),
            layout.authorizedYield
        );
        layout.clearApproval =
            builder.approve(config.funding.asset, config.request, config.approvalLeaf, builder.literal(0));
        recipe = builder.finish();
    }
}
