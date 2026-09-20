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
 * The recipe inserts live principal/yield into policy.consume; runtime supplies current proofs and approved actions. It binds
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

    // Calls and approvals index runtime payloads; numeric Values and consume index instructions.
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
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(32 + config.funding.sources.length);
        builder.check(
            IRecipeExecutor.Operation.Equal,
            builder.read(
                ExecutingRecipe.Read({
                    target: config.requestsFactory,
                    data: abi.encodeCall(IThreeFRequestFactory.isRequest, (config.request)),
                    offset: 0
                })
            ),
            builder.literal(1)
        );
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
        {
            IRecipeExecutor.Binding[] memory bindings = new IRecipeExecutor.Binding[](2);
            bindings[0] = IRecipeExecutor.Binding({offset: 4, value: layout.principal});
            bindings[1] = IRecipeExecutor.Binding({offset: 36, value: layout.authorizedYield});
            layout.consume = builder.call(config.policy, abi.encodeCall(IThreeFPolicy.consume, (0, 0)), bindings);
        }
        (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, layout.principal);
        layout.approve = builder.approve(config.funding.asset, config.request, config.approvalLeaf, layout.principal);
        builder.check(IRecipeExecutor.Operation.Equal, layout.authorizedYield, builder.read(authorization));
        authorization.offset = 0;
        builder.check(IRecipeExecutor.Operation.Equal, layout.principal, builder.read(authorization));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = config.mintLeaf;
        IRecipeExecutor.Value[3] memory beforeValues;
        beforeValues[0] = builder.balance(config.funding.asset, config.funding.account);
        ExecutingRecipe.Read memory shares = ExecutingRecipe.Read({
            target: config.request,
            data: abi.encodeCall(IThreeFVaultController.balancesOf, (config.funding.account)),
            offset: 0
        });
        beforeValues[1] = builder.read(shares);
        shares.offset = 32;
        beforeValues[2] = builder.read(shares);
        layout.operation = builder.manage(leaves, layout.principal);
        builder.check(
            IRecipeExecutor.Operation.Equal,
            builder.binary(
                IRecipeExecutor.Operation.Sub,
                beforeValues[0],
                builder.balance(config.funding.asset, config.funding.account)
            ),
            layout.principal
        );
        builder.check(
            IRecipeExecutor.Operation.Equal,
            builder.binary(IRecipeExecutor.Operation.Sub, builder.read(shares), beforeValues[2]),
            layout.authorizedYield
        );
        shares.offset = 0;
        builder.check(
            IRecipeExecutor.Operation.Equal,
            builder.binary(IRecipeExecutor.Operation.Sub, builder.read(shares), beforeValues[1]),
            layout.principal
        );
        layout.clearApproval =
            builder.approve(config.funding.asset, config.request, config.approvalLeaf, builder.literal(0));
        recipe = builder.finish();
    }
}
