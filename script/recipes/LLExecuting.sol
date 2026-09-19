// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {ILiquidLaneConnector} from "src/interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";
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
        uint256 amountIn;
        uint256 amountOut;
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
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(80 + 12 * config.funding.sources.length);
        layout.amountIn = builder.input(0);
        layout.amountOut = builder.input(1);
        builder.binary(IRecipeExecutor.Operation.LessOrEqual, ExecutingRecipe.ONE, layout.amountIn);
        builder.binary(IRecipeExecutor.Operation.LessOrEqual, layout.amountIn, builder.literal(config.maxAmountIn));
        builder.binary(
            IRecipeExecutor.Operation.LessOrEqual, layout.amountOut, builder.literal(config.maxFundingAmount)
        );
        uint256 beforeRwa;
        {
            _checkConnector(builder, config);
            uint256 beforeCash;
            (layout.sourceCalls, layout.sourceAmounts, beforeCash) = builder.fund(config.funding, layout.amountOut);
            layout.approve =
                builder.approve(config.funding.asset, config.connector, config.approvalLeaf, layout.amountOut);
            _checkConnector(builder, config);
            beforeRwa = builder.balance(config.rwa, config.funding.adapter);
            uint256 beforeRecipient = builder.balance(config.funding.asset, config.recipient);
            {
                bytes32[] memory leaves = new bytes32[](1);
                leaves[0] = config.swapLeaf;
                layout.operation = builder.manage(leaves, layout.amountIn);
            }
            layout.clearApproval =
                builder.approve(config.funding.asset, config.connector, config.approvalLeaf, ExecutingRecipe.ZERO);
            builder.binary(
                IRecipeExecutor.Operation.Equal,
                builder.binary(
                    IRecipeExecutor.Operation.Subtract,
                    beforeCash,
                    builder.balance(config.funding.asset, config.funding.adapter)
                ),
                layout.amountOut
            );
            builder.binary(
                IRecipeExecutor.Operation.Equal,
                builder.binary(
                    IRecipeExecutor.Operation.Subtract,
                    builder.balance(config.funding.asset, config.recipient),
                    beforeRecipient
                ),
                layout.amountOut
            );
            uint256 afterRwa = builder.balance(config.rwa, config.funding.adapter);
            builder.binary(
                IRecipeExecutor.Operation.Equal,
                builder.binary(IRecipeExecutor.Operation.Subtract, afterRwa, beforeRwa),
                layout.amountIn
            );
        }
        if (config.redemption.leaves.length > 0) {
            uint256 beforeReceipt = builder.read(config.redemption.receipt);
            if (config.redemption.spender != address(0)) {
                layout.redeemApprove = builder.approve(
                    config.rwa, config.redemption.spender, config.redemption.approvalLeaf, layout.amountIn
                );
            }
            layout.redeem = builder.manage(config.redemption.leaves, layout.amountIn);
            if (config.redemption.spender != address(0)) {
                layout.redeemClearApproval = builder.approve(
                    config.rwa, config.redemption.spender, config.redemption.approvalLeaf, ExecutingRecipe.ZERO
                );
            }
            builder.binary(
                IRecipeExecutor.Operation.Equal, builder.balance(config.rwa, config.funding.adapter), beforeRwa
            );
            uint256 afterReceipt = builder.read(config.redemption.receipt);
            uint256 received = builder.binary(IRecipeExecutor.Operation.Subtract, afterReceipt, beforeReceipt);
            builder.binary(IRecipeExecutor.Operation.LessOrEqual, ExecutingRecipe.ONE, received);
            builder.binary(
                IRecipeExecutor.Operation.LessOrEqual,
                builder.mulDiv(
                    layout.amountIn,
                    builder.literal(config.redemption.minReceiptNumerator),
                    builder.literal(config.redemption.receiptDenominator)
                ),
                received
            );
            builder.binary(
                IRecipeExecutor.Operation.LessOrEqual,
                afterReceipt,
                builder.literal(config.redemption.maxReceiptBalance)
            );
        }
        builder.checkReserves(config.funding);
        recipe = builder.finish();
    }

    function _checkConnector(ExecutingRecipe.Builder memory builder, Config memory config) private pure {
        builder.binary(
            IRecipeExecutor.Operation.Equal,
            builder.read(
                ExecutingRecipe.Read(config.connector, abi.encodeCall(ILiquidLaneConnector.inputAsset, ()), 0)
            ),
            builder.literal(uint256(uint160(config.funding.asset)))
        );
        builder.binary(
            IRecipeExecutor.Operation.Equal,
            builder.read(ExecutingRecipe.Read(config.connector, abi.encodeCall(ILiquidLaneConnector.adapter, ()), 0)),
            builder.literal(uint256(uint160(config.funding.adapter)))
        );
    }
}
