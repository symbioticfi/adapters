// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

/**
 * @title LLExecuting
 * @notice Library for ordered funding, a signed Liquid Lane swap and optional RWA redemption.
 * @dev Inputs are the RWA amount and quoted funding amount. The swap leaf must pin LiquidLaneConnector's
 * signed swap selector, RWA and recipient. The connector verifies both
 * signatures, enforces the owner-configured minimum discount and computes the live price; exact balance checks bind the quote and amount to the swap.
 * Source and redemption leaves must pin recipients and all non-amount policy. No specialized executor
 * is called. Redemption leaves execute in their configured order and must consume exactly the new RWA.
 */
library LLExecuting {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    struct Redemption {
        address spender;
        bytes32 approvalLeaf;
        bytes32[] leaves;
        ExecutingRecipe.Read receipt;
        uint256 minReceiptNumerator;
        uint256 receiptDenominator;
        uint256 maxReceiptBalance;
    }

    struct Config {
        ExecutingRecipe.Funding funding;
        address connector;
        address rwa;
        address recipient;
        bytes32 approvalLeaf;
        bytes32 swapLeaf;
        uint256 maxAmountIn;
        uint256 maxFundingAmount;
        Redemption redemption;
    }

    struct Layout {
        uint256[] sourceCalls;
        uint256[] sourceAmounts;
        IRecipeExecutor.Value amountIn;
        IRecipeExecutor.Value amountOut;
        uint256 approve;
        uint256 operation;
        uint256 clearApproval;
        uint256 redeemApprove;
        uint256 redeem;
        uint256 redeemClearApproval;
    }

    function build(Config memory config)
        internal
        pure
        returns (IRecipeExecutor.Step[] memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(32 + config.funding.sources.length);
        layout.amountIn = builder.input(0);
        layout.amountOut = builder.input(1);
        builder.check(IRecipeExecutor.Comparison.LessOrEqual, builder.literal(1), layout.amountIn);
        builder.check(IRecipeExecutor.Comparison.LessOrEqual, layout.amountIn, builder.literal(config.maxAmountIn));
        builder.check(
            IRecipeExecutor.Comparison.LessOrEqual, layout.amountOut, builder.literal(config.maxFundingAmount)
        );
        (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, layout.amountOut);
        layout.approve = builder.approve(config.funding.asset, config.connector, config.approvalLeaf, layout.amountOut);
        {
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = config.swapLeaf;
            IRecipeExecutor.Binding[][] memory bindings = new IRecipeExecutor.Binding[][](1);
            bindings[0] = new IRecipeExecutor.Binding[](1);
            bindings[0][0] = IRecipeExecutor.Binding(100, layout.amountIn);
            layout.operation = builder.manage(leaves, layout.amountIn, bindings);
        }
        builder.checkAfter(
            IRecipeExecutor.Comparison.Equal,
            builder.observe(
                ExecutingRecipe.balanceQuery(config.funding.asset, config.funding.adapter),
                IRecipeExecutor.ObservationKind.Decrease
            ),
            layout.amountOut
        );
        builder.checkAfter(
            IRecipeExecutor.Comparison.Equal,
            builder.observe(
                ExecutingRecipe.balanceQuery(config.funding.asset, config.recipient),
                IRecipeExecutor.ObservationKind.Increase
            ),
            layout.amountOut
        );
        builder.checkAfter(
            IRecipeExecutor.Comparison.Equal,
            builder.observe(
                ExecutingRecipe.balanceQuery(config.rwa, config.funding.adapter),
                IRecipeExecutor.ObservationKind.Increase
            ),
            layout.amountIn
        );
        layout.clearApproval =
            builder.approve(config.funding.asset, config.connector, config.approvalLeaf, builder.literal(0));
        if (config.redemption.leaves.length > 0) {
            IRecipeExecutor.Value memory minimum = builder.mulDiv(
                layout.amountIn,
                builder.literal(config.redemption.minReceiptNumerator),
                builder.literal(config.redemption.receiptDenominator)
            );
            if (config.redemption.spender != address(0)) {
                layout.redeemApprove = builder.approve(
                    config.rwa, config.redemption.spender, config.redemption.approvalLeaf, layout.amountIn
                );
            }
            layout.redeem = builder.manage(config.redemption.leaves, layout.amountIn);
            builder.checkAfter(
                IRecipeExecutor.Comparison.Equal,
                builder.observe(
                    ExecutingRecipe.balanceQuery(config.rwa, config.funding.adapter),
                    IRecipeExecutor.ObservationKind.Decrease
                ),
                layout.amountIn
            );
            IRecipeExecutor.Value memory received = builder.observe(
                ExecutingRecipe.query(config.redemption.receipt), IRecipeExecutor.ObservationKind.Increase
            );
            builder.checkAfter(IRecipeExecutor.Comparison.LessOrEqual, builder.literal(1), received);
            builder.checkAfter(IRecipeExecutor.Comparison.LessOrEqual, minimum, received);
            builder.checkAfter(
                IRecipeExecutor.Comparison.LessOrEqual,
                builder.observe(
                    ExecutingRecipe.query(config.redemption.receipt), IRecipeExecutor.ObservationKind.After
                ),
                builder.literal(config.redemption.maxReceiptBalance)
            );
            if (config.redemption.spender != address(0)) {
                layout.redeemClearApproval = builder.approve(
                    config.rwa, config.redemption.spender, config.redemption.approvalLeaf, builder.literal(0)
                );
            }
        }
        recipe = builder.finish();
    }
}
