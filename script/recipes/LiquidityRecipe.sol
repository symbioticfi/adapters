// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ILiquidLaneConnector} from "src/interfaces/merkle-adapter/ILiquidLaneConnector.sol";
import {ILiquidLaneExecutor} from "src/interfaces/periphery/ILiquidLaneExecutor.sol";
import {IRecipeExecutor} from "src/interfaces/periphery/IRecipeExecutor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LiquidityRecipe
 * @notice Library for bounding ordered funding, Liquid Lane swaps and redemption, and 3F minting.
 * @dev The typed executor owns source order, exact funding checks, signatures and Merkle authorization.
 * Its operation leaf must pin the same connector, RWA and recipient, and its caller must be the recipe
 * executor. Only the recipe executor's caller is assigned to the provider. No provider leaf roles are needed.
 * With redemption enabled, receiptToken is a distinct issuer claim token: burning RWA alone cannot pass.
 * With redemption disabled, clear the typed executor's post-action leaves and use the RWA as receiptToken.
 * The receipt balance cap bounds outstanding holdings, not lifetime turnover or issuer creditworthiness.
 */
library LiquidityRecipe {
    struct Configuration {
        address executor;
        address adapter;
        address connector;
        address rwa;
        address receiptToken;
        uint256 maxAmountIn;
        uint256 maxFundingAmount;
        uint256 minReceiptNumerator;
        uint256 receiptDenominator;
        uint256 maxReceiptBalance;
    }

    uint256 internal constant INVOKE_STEP = 11;

    /**
     * @notice Builds a recipe whose only runtime payload is the complete typed swap calldata at step 11.
     * @dev amountIn is the fourth ABI head word (byte offset 100), independent of dynamic tail layout.
     * The current gross quote for maxAmountIn bounds funding spend because connector quotes are monotonic
     * in amount and the typed executor validates the discounted quote again after preparing liquidity.
     * Receipt units and rounding are curator policy; MulDiv rounds the minimum receipt requirement down.
     */
    function liquidLane(Configuration memory config) internal pure returns (IRecipeExecutor.Step[] memory recipe) {
        recipe = new IRecipeExecutor.Step[](16);
        recipe[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, config.maxAmountIn, 0, 0, "");
        recipe[1] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Calldata, INVOKE_STEP, 100, 0, "");
        recipe[2] = IRecipeExecutor.Step(IRecipeExecutor.Operation.LessOrEqual, 1, 0, 0, "");
        recipe[3] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Read,
            0,
            0,
            0,
            abi.encode(
                config.connector, abi.encodeCall(ILiquidLaneConnector.getAmountOut, (config.rwa, config.maxAmountIn))
            )
        );
        recipe[4] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, config.maxFundingAmount, 0, 0, "");
        recipe[5] = IRecipeExecutor.Step(IRecipeExecutor.Operation.LessOrEqual, 3, 4, 0, "");
        recipe[6] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Read,
            0,
            0,
            0,
            abi.encode(config.receiptToken, abi.encodeCall(IERC20.balanceOf, (config.adapter)))
        );
        recipe[7] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, config.minReceiptNumerator, 0, 0, "");
        recipe[8] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, config.receiptDenominator, 0, 0, "");
        recipe[9] = IRecipeExecutor.Step(IRecipeExecutor.Operation.MulDiv, 1, 7, 8, "");
        recipe[10] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, config.maxReceiptBalance, 0, 0, "");
        recipe[INVOKE_STEP] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Invoke, 0, 0, 0, abi.encode(config.executor, ILiquidLaneExecutor.swap.selector)
        );
        recipe[12] = recipe[6];
        recipe[13] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Subtract, 12, 6, 0, "");
        recipe[14] = IRecipeExecutor.Step(IRecipeExecutor.Operation.LessOrEqual, 9, 13, 0, "");
        recipe[15] = IRecipeExecutor.Step(IRecipeExecutor.Operation.LessOrEqual, 12, 10, 0, "");
    }
}
