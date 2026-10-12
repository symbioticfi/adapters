// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OP_EQUAL, OP_LESS_OR_EQUAL, OP_SUB} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

/**
 * @title LLExecuting
 * @notice Library for ordered funding, a signed Liquid Lane swap and optional RWA redemption.
 * @dev Inputs are the RWA amount and quoted funding amount. The swap leaf must pin LiquidLaneConnector's
 * signed swap selector and RWA. The recipe checks the configured recipient's exact payment delta;
 * the swap leaf need not pin its recipient. The connector verifies both
 * signatures, enforces the owner-configured minimum discount and computes the live price; exact balance checks bind the quote and amount to the swap.
 * Configure source and redemption leaves for the intended markets, assets and payout rules. No specialized executor
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
        // Maximum new receipt units per execution; existing receipts do not consume this limit.
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
        bool skipZeroApprovals;
        Redemption redemption;
    }

    // Calls and approvals index runtime payloads; packed result operands reference instructions.
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
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(32 + config.funding.sources.length);
        layout.amountIn = builder.input(0);
        layout.amountOut = builder.input(1);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), layout.amountIn);
        builder.check(OP_LESS_OR_EQUAL, layout.amountIn, builder.literal(config.maxAmountIn));
        builder.check(OP_LESS_OR_EQUAL, layout.amountOut, builder.literal(config.maxFundingAmount));
        (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, layout.amountOut);
        layout.approve = builder.approve(config.funding.asset, config.connector, config.approvalLeaf, layout.amountOut);
        {
            uint256 cash = builder.balance(config.funding.asset, config.funding.account);
            uint256 paid = builder.balance(config.funding.asset, config.recipient);
            uint256 rwa = builder.balance(config.rwa, config.funding.account);
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = config.swapLeaf;
            uint256[][] memory bindings = new uint256[][](1);
            bindings[0] = new uint256[](1);
            bindings[0][0] = ExecutingRecipe.binding(100, layout.amountIn);
            layout.operation = builder.manage(leaves, layout.amountIn, bindings);
            builder.check(
                OP_EQUAL,
                builder.binary(OP_SUB, cash, builder.balance(config.funding.asset, config.funding.account)),
                layout.amountOut
            );
            builder.check(
                OP_EQUAL,
                builder.binary(OP_SUB, builder.balance(config.funding.asset, config.recipient), paid),
                layout.amountOut
            );
            builder.check(
                OP_EQUAL,
                builder.binary(OP_SUB, builder.balance(config.rwa, config.funding.account), rwa),
                layout.amountIn
            );
        }
        layout.clearApproval = builder.clearApproval(
            config.funding.asset, config.connector, config.approvalLeaf, config.skipZeroApprovals
        );
        if (config.redemption.leaves.length > 0) {
            uint256 minimum = builder.mulDiv(
                layout.amountIn,
                builder.literal(config.redemption.minReceiptNumerator),
                builder.literal(config.redemption.receiptDenominator)
            );
            if (config.redemption.spender != address(0)) {
                layout.redeemApprove = builder.approve(
                    config.rwa, config.redemption.spender, config.redemption.approvalLeaf, layout.amountIn
                );
            }
            uint256 rwa = builder.balance(config.rwa, config.funding.account);
            uint256 receipt = builder.read(config.redemption.receipt);
            layout.redeem = builder.manage(config.redemption.leaves, layout.amountIn);
            builder.check(
                OP_EQUAL,
                builder.binary(OP_SUB, rwa, builder.balance(config.rwa, config.funding.account)),
                layout.amountIn
            );
            uint256 total = builder.read(config.redemption.receipt);
            uint256 received = builder.binary(OP_SUB, total, receipt);
            builder.check(OP_LESS_OR_EQUAL, builder.literal(1), received);
            builder.check(OP_LESS_OR_EQUAL, minimum, received);
            builder.check(OP_LESS_OR_EQUAL, received, builder.literal(config.redemption.maxReceiptBalance));
            if (config.redemption.spender != address(0)) {
                layout.redeemClearApproval = builder.clearApproval(
                    config.rwa, config.redemption.spender, config.redemption.approvalLeaf, config.skipZeroApprovals
                );
            }
        }
        recipe = builder.finish();
    }
}
