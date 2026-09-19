// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {IRecipeExecutor} from "src/interfaces/periphery/IRecipeExecutor.sol";
import {IThreeFPolicy} from "src/interfaces/periphery/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";

/**
 * @title ThreeFExecuting
 * @notice Library for native 3F funding and minting entirely through RecipeExecutor.
 * @dev Bind a ThreeFPolicy to this RecipeExecutor and let its owner configure yield and period budget.
 * Runtime supplies the live principal/yield to policy.consume and current proofs. The recipe binds
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
        uint256 principal;
        uint256 authorizedYield;
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
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(80 + 12 * config.funding.sources.length);
        builder.binary(
            IRecipeExecutor.Operation.Equal,
            builder.read(
                ExecutingRecipe.Read(
                    config.requestsFactory, abi.encodeCall(IThreeFRequestFactory.isRequest, (config.request)), 0
                )
            ),
            ExecutingRecipe.ONE
        );
        ExecutingRecipe.Read memory authorization = ExecutingRecipe.Read(
            config.request, abi.encodeCall(IThreeFPushRequest.mintAuthorization, (config.funding.adapter)), 0
        );
        layout.principal = builder.read(authorization);
        authorization.offset = 32;
        layout.authorizedYield = builder.read(authorization);
        builder.binary(IRecipeExecutor.Operation.LessOrEqual, ExecutingRecipe.ONE, layout.principal);
        builder.binary(IRecipeExecutor.Operation.LessOrEqual, layout.principal, builder.literal(config.maxPrincipal));
        // Authenticate both top-level policy arguments before its invocation.
        layout.consume = builder.length + 4;
        for (uint256 i; i < 2; ++i) {
            uint256 argument = builder.length;
            builder.recipe[builder.length++] =
                IRecipeExecutor.Step(IRecipeExecutor.Operation.Calldata, layout.consume, 4 + i * 32, 0, "");
            builder.binary(
                IRecipeExecutor.Operation.Equal, argument, i == 0 ? layout.principal : layout.authorizedYield
            );
        }
        builder.recipe[builder.length++] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Invoke, 0, 0, 0, abi.encode(config.policy, IThreeFPolicy.consume.selector)
        );
        uint256[3] memory beforeValues;
        (layout.sourceCalls, layout.sourceAmounts, beforeValues[0]) = builder.fund(config.funding, layout.principal);
        layout.approve = builder.approve(config.funding.asset, config.request, config.approvalLeaf, layout.principal);
        builder.binary(IRecipeExecutor.Operation.Equal, layout.authorizedYield, builder.read(authorization));
        authorization.offset = 0;
        builder.binary(IRecipeExecutor.Operation.Equal, layout.principal, builder.read(authorization));
        ExecutingRecipe.Read memory shares = ExecutingRecipe.Read(
            config.request, abi.encodeCall(IThreeFVaultController.balancesOf, (config.funding.adapter)), 0
        );
        beforeValues[1] = builder.read(shares);
        shares.offset = 32;
        beforeValues[2] = builder.read(shares);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = config.mintLeaf;
        layout.operation = builder.manage(leaves, layout.principal);
        layout.clearApproval =
            builder.approve(config.funding.asset, config.request, config.approvalLeaf, ExecutingRecipe.ZERO);
        builder.binary(
            IRecipeExecutor.Operation.Equal,
            builder.binary(
                IRecipeExecutor.Operation.Subtract,
                beforeValues[0],
                builder.balance(config.funding.asset, config.funding.adapter)
            ),
            layout.principal
        );
        builder.binary(
            IRecipeExecutor.Operation.Equal,
            builder.binary(IRecipeExecutor.Operation.Subtract, builder.read(shares), beforeValues[2]),
            layout.authorizedYield
        );
        shares.offset = 0;
        builder.binary(
            IRecipeExecutor.Operation.Equal,
            builder.binary(IRecipeExecutor.Operation.Subtract, builder.read(shares), beforeValues[1]),
            layout.principal
        );
        builder.checkReserves(config.funding);
        recipe = builder.finish();
    }
}
