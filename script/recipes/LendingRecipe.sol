// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {
    OP_ADD,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_SATURATING_SUB,
    OP_SUB
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LendingRecipe
 * @notice Library for building an LBTC supply, USDC borrow and RWA purchase or subscription request recipe offchain.
 * @dev LBTC and its receipt use 8 decimals, USDC and its variable debt use 6, and RWA uses 18.
 * Input 0 is LBTC base units to supply; input 1 is USDC base units to borrow and spend.
 * The protocol leaves must pin the MerkleAccount as account/recipient, the lending market, rate mode,
 * health query, literal minimum health factor and purchase asset. Only amounts may vary.
 * purchaseReceipt optionally measures new queued entitlement in raw RWA units instead of immediate token delivery.
 * Use a separate ClaimRecipe after issuer settlement; the request must not claim or spend the assets twice.
 * The borrowing leaf must call stateless RecipeCapability.execute with the health condition pinned.
 * Reads measure actual token movements; receipt/debt growth may differ by at most one base unit
 * from principal to accommodate same-transaction indexed-token rounding. Supply/spend transfers stay exact.
 * This library deploys no helper and grants no permissions: publish its recipe to RecipeExecutor,
 * accept the matching adapter root, and grant the executor the five corresponding leaf roles.
 */
library LendingRecipe {
    using ExecutingRecipe for ExecutingRecipe.Builder;
    /* STRUCTS */

    struct Config {
        address account;
        address lbtc;
        address usdc;
        address rwa;
        address collateralReceipt;
        address variableDebt;
        address pool;
        address issuer;
        ExecutingRecipe.Read purchaseReceipt;
        bool skipZeroApprovals; // Reserved legacy option; cleanup uses ordinary Approve(0).
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
        uint256 borrowedUsdc;
        uint256 minimumRwa;
        uint256 rwaReceived;
    }

    function build(Config memory config, Limits memory limits)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(16);
        uint256 initialCash = builder.balance(config.usdc, config.account);
        {
            uint256 supply = builder.input(0);
            uint256 borrowAmount = builder.input(1);
            builder.check(OP_LESS_OR_EQUAL, builder.literal(1), supply);
            builder.check(OP_LESS_OR_EQUAL, builder.literal(1), borrowAmount);
            builder.check(OP_LESS_OR_EQUAL, supply, builder.literal(limits.maxSupplyLbtc));
            builder.check(
                OP_LESS_OR_EQUAL,
                borrowAmount,
                builder.binary(
                    OP_SATURATING_SUB,
                    builder.literal(limits.maxTotalDebtUsdc),
                    builder.balance(config.variableDebt, config.account)
                )
            );
            builder.approve(config.lbtc, config.pool, config.collateralApprovalLeaf, supply);
            {
                uint256 lbtc = builder.balance(config.lbtc, config.account);
                uint256 receipt = builder.balance(config.collateralReceipt, config.account);
                builder.manage(_leaf(config.supplyLeaf), supply, _bindings(config.supplyAmountOffsets, supply));
                uint256 spent = builder.binary(OP_SUB, lbtc, builder.balance(config.lbtc, config.account));
                uint256 received =
                    builder.binary(OP_SUB, builder.balance(config.collateralReceipt, config.account), receipt);
                builder.check(OP_EQUAL, spent, supply);
                _rounding(builder, spent, received);
            }
            {
                uint256 cash = builder.balance(config.usdc, config.account);
                uint256 debtBefore = builder.balance(config.variableDebt, config.account);
                builder.manage(
                    _leaf(config.borrowLeaf), borrowAmount, _bindings(config.borrowAmountOffsets, borrowAmount)
                );
                layout.borrowedUsdc = builder.binary(OP_SUB, builder.balance(config.usdc, config.account), cash);
                uint256 totalDebt = builder.balance(config.variableDebt, config.account);
                uint256 debt = builder.binary(OP_SUB, totalDebt, debtBefore);
                builder.check(OP_EQUAL, layout.borrowedUsdc, borrowAmount);
                _rounding(builder, layout.borrowedUsdc, debt);
                builder.check(OP_LESS_OR_EQUAL, totalDebt, builder.literal(limits.maxTotalDebtUsdc));
            }
        }
        layout.minimumRwa =
            builder.mulDiv(layout.borrowedUsdc, builder.literal(limits.minRwaPerUsdcWad), builder.literal(1e6));
        builder.approve(config.usdc, config.issuer, config.purchaseApprovalLeaf, layout.borrowedUsdc);
        {
            uint256 cash = builder.balance(config.usdc, config.account);
            uint256 rwa = config.purchaseReceipt.target > address(0)
                ? builder.read(config.purchaseReceipt)
                : builder.balance(config.rwa, config.account);
            builder.manage(
                _leaf(config.purchaseLeaf),
                layout.borrowedUsdc,
                _bindings(config.purchaseAmountOffsets, layout.borrowedUsdc)
            );
            builder.check(
                OP_EQUAL,
                builder.binary(OP_SUB, cash, builder.balance(config.usdc, config.account)),
                layout.borrowedUsdc
            );
            layout.rwaReceived = builder.binary(
                OP_SUB,
                config.purchaseReceipt.target > address(0)
                    ? builder.read(config.purchaseReceipt)
                    : builder.balance(config.rwa, config.account),
                rwa
            );
            builder.check(OP_LESS_OR_EQUAL, builder.literal(1), layout.rwaReceived);
            builder.check(OP_LESS_OR_EQUAL, layout.minimumRwa, layout.rwaReceived);
        }
        builder.clearApproval(config.lbtc, config.pool, config.collateralApprovalLeaf, config.skipZeroApprovals);
        builder.clearApproval(config.usdc, config.issuer, config.purchaseApprovalLeaf, config.skipZeroApprovals);
        builder.check(OP_EQUAL, builder.balance(config.usdc, config.account), initialCash);
        recipe = builder.finish();
    }

    function _rounding(ExecutingRecipe.Builder memory builder, uint256 requested, uint256 actual) private pure {
        builder.check(OP_LESS_OR_EQUAL, actual, builder.binary(OP_ADD, requested, builder.literal(1)));
        builder.check(OP_LESS_OR_EQUAL, requested, builder.binary(OP_ADD, actual, builder.literal(1)));
    }

    function _leaf(bytes32 leaf) private pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](1);
        leaves[0] = leaf;
    }

    function _bindings(uint256[] memory offsets, uint256 amount) private pure returns (uint256[][] memory bindings) {
        bindings = new uint256[][](1);
        uint256 length = offsets.length;
        bindings[0] = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            bindings[0][i] = ExecutingRecipe.binding(offsets[i], amount);
        }
    }
}
