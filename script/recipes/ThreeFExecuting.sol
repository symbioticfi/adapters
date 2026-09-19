// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {IRecipeExecutor} from "src/interfaces/periphery/IRecipeExecutor.sol";
import {IThreeFCapability} from "src/interfaces/merkle-adapter/capabilities/IThreeFCapability.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";

/**
 * @title ThreeFExecuting
 * @notice Library for a complete ordered-funding and 3F mint recipe without a ThreeFExecutor.
 * @dev Give RecipeExecutor the configured source, approval and mint leaf roles. The mint leaf must
 * pin this request; the approval leaf must pin the request as spender. Authorization, exact principal
 * spend and recorded exposure are checked directly. ThreeFCapability enforces request eligibility,
 * deadline, protocol yield and period budgets. Runtime inputs are empty; actions carry current proofs.
 */
library ThreeFExecuting {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    struct Config {
        ExecutingRecipe.Funding funding;
        address request;
        bytes32 approvalLeaf;
        bytes32 mintLeaf;
        uint256 maxPrincipal;
        uint256 minYield;
        uint256 maxPositionAssets;
    }

    struct Layout {
        uint256[] sourceCalls;
        uint256[] sourceAmounts;
        uint256 principal;
        uint256 approve;
        uint256 operation;
        uint256 clearApproval;
    }

    function build(Config memory config)
        internal
        pure
        returns (IRecipeExecutor.Step[] memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(64 + 12 * config.funding.sources.length);
        ExecutingRecipe.Read memory authorization = ExecutingRecipe.Read(
            config.request, abi.encodeCall(IThreeFPushRequest.mintAuthorization, (config.funding.adapter)), 0
        );
        layout.principal = builder.read(authorization);
        authorization.offset = 32;
        uint256 authorizedYield = builder.read(authorization);
        builder.binary(IRecipeExecutor.Operation.LessOrEqual, ExecutingRecipe.ONE, layout.principal);
        builder.binary(IRecipeExecutor.Operation.LessOrEqual, layout.principal, builder.literal(config.maxPrincipal));
        builder.binary(IRecipeExecutor.Operation.LessOrEqual, builder.literal(config.minYield), authorizedYield);
        uint256 beforePosition = builder.read(
            ExecutingRecipe.Read(config.funding.adapter, abi.encodeCall(IThreeFCapability.threeFPositionAssets, ()), 0)
        );
        uint256 beforeCash;
        (layout.sourceCalls, layout.sourceAmounts, beforeCash) = builder.fund(config.funding, layout.principal);
        layout.approve = builder.approve(config.funding.asset, config.request, config.approvalLeaf, layout.principal);
        builder.binary(IRecipeExecutor.Operation.Equal, authorizedYield, builder.read(authorization));
        authorization.offset = 0;
        builder.binary(IRecipeExecutor.Operation.Equal, layout.principal, builder.read(authorization));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = config.mintLeaf;
        layout.operation = builder.manage(leaves, layout.principal);
        layout.clearApproval =
            builder.approve(config.funding.asset, config.request, config.approvalLeaf, ExecutingRecipe.ZERO);
        builder.binary(
            IRecipeExecutor.Operation.Equal,
            builder.binary(
                IRecipeExecutor.Operation.Subtract,
                beforeCash,
                builder.balance(config.funding.asset, config.funding.adapter)
            ),
            layout.principal
        );
        builder.binary(
            IRecipeExecutor.Operation.Equal,
            builder.read(
                ExecutingRecipe.Read(
                    config.funding.adapter, abi.encodeCall(IThreeFCapability.pendingAssets, (config.request)), 0
                )
            ),
            layout.principal
        );
        uint256 afterPosition = builder.read(
            ExecutingRecipe.Read(config.funding.adapter, abi.encodeCall(IThreeFCapability.threeFPositionAssets, ()), 0)
        );
        builder.binary(
            IRecipeExecutor.Operation.Equal,
            builder.binary(IRecipeExecutor.Operation.Subtract, afterPosition, beforePosition),
            layout.principal
        );
        builder.binary(IRecipeExecutor.Operation.LessOrEqual, afterPosition, builder.literal(config.maxPositionAssets));
        builder.checkReserves(config.funding);
        recipe = builder.finish();
    }
}
