// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LendingRecipe
 * @notice Library for building an LBTC supply, USDC borrow and immediate RWA purchase recipe offchain.
 * @dev LBTC and its receipt use 8 decimals, USDC and its variable debt use 6, and RWA uses 18.
 * Input 0 is LBTC base units to supply; input 1 is USDC base units to borrow and spend.
 * The protocol leaves must pin the adapter as account/recipient, the lending market, rate mode,
 * health query, literal minimum health factor and purchase asset. Only amounts may vary.
 * The borrowing leaf must call stateless GuardedCallsCapability.execute with the health condition pinned.
 * Reads measure actual token movements; receipt/debt growth may differ by at most one base unit
 * from principal to accommodate same-transaction indexed-token rounding. Supply/spend transfers stay exact.
 * This library deploys no helper and grants no permissions: publish its recipe to RecipeExecutor,
 * accept the matching adapter root, and grant the executor the five corresponding leaf roles.
 */
library LendingRecipe {
    using ExecutingRecipe for ExecutingRecipe.Builder;
    /* STRUCTS */

    struct Config {
        address adapter;
        address lbtc;
        address usdc;
        address rwa;
        address collateralReceipt;
        address variableDebt;
        address pool;
        address issuer;
        bytes32 collateralApprovalLeaf;
        bytes32 supplyLeaf;
        bytes32 borrowLeaf;
        bytes32 purchaseApprovalLeaf;
        bytes32 purchaseLeaf;
        uint256[] supplyAmountOffsets;
        uint256[] borrowAmountOffsets;
        uint256[] purchaseAmountOffsets;
    }

    struct Limits {
        uint256 maxSupplyLbtc;
        uint256 maxTotalDebtUsdc;
        // Minimum whole RWA tokens per whole USDC, scaled by 1e18; 0.99e18 permits a 1% output shortfall to par.
        uint256 minRwaPerUsdcWad;
    }

    enum Action {
        ApproveLbtc,
        SupplyCall,
        BorrowCall,
        ApproveUsdc,
        PurchaseCall,
        ClearLbtcApproval,
        ClearUsdcApproval,
        Length
    }

    struct Layout {
        IRecipeExecutor.Value borrowedUsdc;
        IRecipeExecutor.Value minimumRwa;
        IRecipeExecutor.Value rwaReceived;
    }

    function build(Config memory config, Limits memory limits)
        internal
        pure
        returns (IRecipeExecutor.Step[] memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(16);
        IRecipeExecutor.Value memory supply = builder.input(0);
        IRecipeExecutor.Value memory borrowAmount = builder.input(1);
        IRecipeExecutor.Value memory initialCash = builder.balance(config.usdc, config.adapter);
        builder.check(IRecipeExecutor.Comparison.LessOrEqual, builder.literal(1), supply);
        builder.check(IRecipeExecutor.Comparison.LessOrEqual, builder.literal(1), borrowAmount);
        builder.check(IRecipeExecutor.Comparison.LessOrEqual, supply, builder.literal(limits.maxSupplyLbtc));
        builder.check(
            IRecipeExecutor.Comparison.LessOrEqual,
            borrowAmount,
            builder.binary(
                IRecipeExecutor.Operation.SaturatingSubtract,
                builder.literal(limits.maxTotalDebtUsdc),
                builder.balance(config.variableDebt, config.adapter)
            )
        );
        builder.approve(config.lbtc, config.pool, config.collateralApprovalLeaf, supply);
        builder.manage(_leaf(config.supplyLeaf), supply, _bindings(config.supplyAmountOffsets, supply));
        {
            IRecipeExecutor.Value memory spent = builder.observe(
                ExecutingRecipe.balanceQuery(config.lbtc, config.adapter), IRecipeExecutor.ObservationKind.Decrease
            );
            IRecipeExecutor.Value memory received = builder.observe(
                ExecutingRecipe.balanceQuery(config.collateralReceipt, config.adapter),
                IRecipeExecutor.ObservationKind.Increase
            );
            builder.checkAfter(IRecipeExecutor.Comparison.Equal, spent, supply);
            _rounding(builder, spent, received);
        }
        builder.manage(_leaf(config.borrowLeaf), borrowAmount, _bindings(config.borrowAmountOffsets, borrowAmount));
        layout.borrowedUsdc = builder.observe(
            ExecutingRecipe.balanceQuery(config.usdc, config.adapter), IRecipeExecutor.ObservationKind.Increase
        );
        {
            IRecipeExecutor.Value memory debt = builder.observe(
                ExecutingRecipe.balanceQuery(config.variableDebt, config.adapter),
                IRecipeExecutor.ObservationKind.Increase
            );
            IRecipeExecutor.Value memory totalDebt = builder.observe(
                ExecutingRecipe.balanceQuery(config.variableDebt, config.adapter), IRecipeExecutor.ObservationKind.After
            );
            builder.checkAfter(IRecipeExecutor.Comparison.Equal, layout.borrowedUsdc, borrowAmount);
            _rounding(builder, layout.borrowedUsdc, debt);
            builder.checkAfter(
                IRecipeExecutor.Comparison.LessOrEqual, totalDebt, builder.literal(limits.maxTotalDebtUsdc)
            );
        }
        layout.minimumRwa =
            builder.mulDiv(layout.borrowedUsdc, builder.literal(limits.minRwaPerUsdcWad), builder.literal(1e6));
        builder.approve(config.usdc, config.issuer, config.purchaseApprovalLeaf, layout.borrowedUsdc);
        builder.manage(
            _leaf(config.purchaseLeaf),
            layout.borrowedUsdc,
            _bindings(config.purchaseAmountOffsets, layout.borrowedUsdc)
        );
        builder.checkAfter(
            IRecipeExecutor.Comparison.Equal,
            builder.observe(
                ExecutingRecipe.balanceQuery(config.usdc, config.adapter), IRecipeExecutor.ObservationKind.Decrease
            ),
            layout.borrowedUsdc
        );
        layout.rwaReceived = builder.observe(
            ExecutingRecipe.balanceQuery(config.rwa, config.adapter), IRecipeExecutor.ObservationKind.Increase
        );
        builder.checkAfter(IRecipeExecutor.Comparison.LessOrEqual, layout.minimumRwa, layout.rwaReceived);
        builder.approve(config.lbtc, config.pool, config.collateralApprovalLeaf, builder.literal(0));
        builder.approve(config.usdc, config.issuer, config.purchaseApprovalLeaf, builder.literal(0));
        builder.checkAfter(
            IRecipeExecutor.Comparison.Equal,
            builder.observe(
                ExecutingRecipe.balanceQuery(config.usdc, config.adapter), IRecipeExecutor.ObservationKind.After
            ),
            initialCash
        );
        recipe = builder.finish();
    }

    function _rounding(
        ExecutingRecipe.Builder memory builder,
        IRecipeExecutor.Value memory requested,
        IRecipeExecutor.Value memory actual
    ) private pure {
        builder.checkAfter(
            IRecipeExecutor.Comparison.LessOrEqual,
            actual,
            builder.afterBinary(IRecipeExecutor.Operation.Add, requested, builder.literal(1))
        );
        builder.checkAfter(
            IRecipeExecutor.Comparison.LessOrEqual,
            requested,
            builder.afterBinary(IRecipeExecutor.Operation.Add, actual, builder.literal(1))
        );
    }

    function _leaf(bytes32 leaf) private pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](1);
        leaves[0] = leaf;
    }

    function _bindings(uint256[] memory offsets, IRecipeExecutor.Value memory amount)
        private
        pure
        returns (IRecipeExecutor.Binding[][] memory bindings)
    {
        bindings = new IRecipeExecutor.Binding[][](1);
        bindings[0] = new IRecipeExecutor.Binding[](offsets.length);
        for (uint256 i; i < offsets.length; ++i) {
            bindings[0][i] = IRecipeExecutor.Binding(offsets[i], amount);
        }
    }
}
