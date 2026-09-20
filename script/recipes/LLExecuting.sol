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

    // Calls and approvals index runtime payloads; numeric Values index instructions.
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
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(32 + config.funding.sources.length);
        layout.amountIn = builder.input(0);
        layout.amountOut = builder.input(1);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, builder.literal(1), layout.amountIn);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, layout.amountIn, builder.literal(config.maxAmountIn));
        builder.check(IRecipeExecutor.Operation.LessOrEqual, layout.amountOut, builder.literal(config.maxFundingAmount));
        (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, layout.amountOut);
        layout.approve = builder.approve(config.funding.asset, config.connector, config.approvalLeaf, layout.amountOut);
        {
            IRecipeExecutor.Value memory cash = builder.balance(config.funding.asset, config.funding.account);
            IRecipeExecutor.Value memory paid = builder.balance(config.funding.asset, config.recipient);
            IRecipeExecutor.Value memory rwa = builder.balance(config.rwa, config.funding.account);
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = config.swapLeaf;
            IRecipeExecutor.Binding[][] memory bindings = new IRecipeExecutor.Binding[][](1);
            bindings[0] = new IRecipeExecutor.Binding[](1);
            bindings[0][0] = IRecipeExecutor.Binding({offset: 100, value: layout.amountIn});
            layout.operation = builder.manage(leaves, layout.amountIn, bindings);
            builder.check(
                IRecipeExecutor.Operation.Equal,
                builder.binary(
                    IRecipeExecutor.Operation.Sub, cash, builder.balance(config.funding.asset, config.funding.account)
                ),
                layout.amountOut
            );
            builder.check(
                IRecipeExecutor.Operation.Equal,
                builder.binary(
                    IRecipeExecutor.Operation.Sub, builder.balance(config.funding.asset, config.recipient), paid
                ),
                layout.amountOut
            );
            builder.check(
                IRecipeExecutor.Operation.Equal,
                builder.binary(IRecipeExecutor.Operation.Sub, builder.balance(config.rwa, config.funding.account), rwa),
                layout.amountIn
            );
        }
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
            IRecipeExecutor.Value memory rwa = builder.balance(config.rwa, config.funding.account);
            IRecipeExecutor.Value memory receipt = builder.read(config.redemption.receipt);
            layout.redeem = builder.manage(config.redemption.leaves, layout.amountIn);
            builder.check(
                IRecipeExecutor.Operation.Equal,
                builder.binary(IRecipeExecutor.Operation.Sub, rwa, builder.balance(config.rwa, config.funding.account)),
                layout.amountIn
            );
            IRecipeExecutor.Value memory total = builder.read(config.redemption.receipt);
            IRecipeExecutor.Value memory received = builder.binary(IRecipeExecutor.Operation.Sub, total, receipt);
            builder.check(IRecipeExecutor.Operation.LessOrEqual, builder.literal(1), received);
            builder.check(IRecipeExecutor.Operation.LessOrEqual, minimum, received);
            builder.check(
                IRecipeExecutor.Operation.LessOrEqual, total, builder.literal(config.redemption.maxReceiptBalance)
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
