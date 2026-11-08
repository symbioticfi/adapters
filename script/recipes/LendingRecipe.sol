// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {OP_LESS_OR_EQUAL, OP_MIN, OP_SATURATING_SUB, OP_SUB} from "src/interfaces/merkle-adapter/IRecipes.sol";

/**
 * @title LendingRecipe
 * @notice Library for building an LBTC supply, USDC borrow and RWA purchase or subscription request recipe offchain.
 * @dev LBTC uses 8 decimals, USDC and its variable debt use 6, and RWA uses 18.
 * Supply is the live wallet balance capped by policy; a zero supply skips the supply call, so existing
 * collateral headroom can still be borrowed. Input 0 is executor-calculated borrowing capacity, simulated after supply. Borrowing is capped by live debt headroom, reserving one raw debt unit for rounding.
 * The protocol leaves must pin the MerkleAccount as account/recipient, the lending market, rate mode,
 * and purchase asset. Only amounts may vary.
 * purchaseReceipt optionally measures new queued entitlement in raw RWA units instead of immediate token delivery.
 * Use a separate ClaimRecipe after issuer settlement; the request must not claim or spend the assets twice.
 * The borrowing leaf calls the lending protocol directly; the recipe enforces the configured debt cap
 * and reads native pool health after borrowing, enforcing the configured minimum (at least 1).
 * Native calls own transfers and receipt accounting. The configured minimum RWA output is checked after purchase.
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
        address variableDebt;
        address pool;
        address issuer;
        ExecutingRecipe.Read purchaseReceipt;

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
        // Zero selects the native liquidation floor of 1e18.
        uint256 minHealthFactorWad;
        // Minimum whole RWA tokens per whole USDC, scaled by 1e18; 0.99e18 permits a 1% output shortfall to par.
        uint256 minRwaPerUsdcWad;
    }

    enum Action {
        ApproveLbtc,
        SupplyCall,
        ClearLbtcApproval,
        BorrowCall,
        ApproveUsdc,
        PurchaseCall,
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
        require(limits.minHealthFactorWad == 0 || limits.minHealthFactorWad >= 1e18, "Invalid health floor");
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(16);
        {
            uint256 supply = builder.binary(
                OP_MIN, builder.balance(config.lbtc, config.account), builder.literal(limits.maxSupplyLbtc)
            );
            builder.approve(supply, config.lbtc, config.pool, config.collateralApprovalLeaf);
            builder.manage(supply, _leaf(config.supplyLeaf), _bindings(config.supplyAmountOffsets, supply));
            builder.clearApproval(config.lbtc, config.pool, config.collateralApprovalLeaf);
            {
                uint256 borrowAmount = builder.binary(
                    OP_MIN,
                    builder.input(0),
                    builder.binary(
                        OP_SATURATING_SUB,
                        builder.binary(
                            OP_SATURATING_SUB,
                            builder.literal(limits.maxTotalDebtUsdc),
                            builder.balance(config.variableDebt, config.account)
                        ),
                        builder.literal(1)
                    )
                );
                builder.check(OP_LESS_OR_EQUAL, builder.literal(1), borrowAmount);
                builder.manage(
                    borrowAmount, _leaf(config.borrowLeaf), _bindings(config.borrowAmountOffsets, borrowAmount)
                );
                layout.borrowedUsdc = borrowAmount;
                uint256 health = builder.read(
                    ExecutingRecipe.Read({
                        target: config.pool,
                        data: abi.encodeWithSignature("getUserAccountData(address)", config.account),
                        offset: 160
                    })
                );
                builder.check(
                    OP_LESS_OR_EQUAL,
                    builder.literal(limits.minHealthFactorWad == 0 ? 1e18 : limits.minHealthFactorWad),
                    health
                );
                uint256 totalDebt = builder.balance(config.variableDebt, config.account);
                builder.check(OP_LESS_OR_EQUAL, totalDebt, builder.literal(limits.maxTotalDebtUsdc));
            }
        }
        layout.minimumRwa =
            builder.mulDiv(layout.borrowedUsdc, builder.literal(limits.minRwaPerUsdcWad), builder.literal(1e6));
        builder.approve(layout.borrowedUsdc, config.usdc, config.issuer, config.purchaseApprovalLeaf);
        {
            uint256 rwa;
            if (limits.minRwaPerUsdcWad > 0) {
                rwa = config.purchaseReceipt.target > address(0)
                    ? builder.read(config.purchaseReceipt)
                    : builder.balance(config.rwa, config.account);
            }
            builder.manage(
                layout.borrowedUsdc,
                _leaf(config.purchaseLeaf),
                _bindings(config.purchaseAmountOffsets, layout.borrowedUsdc)
            );
            if (limits.minRwaPerUsdcWad > 0) {
                layout.rwaReceived = builder.binary(
                    OP_SUB,
                    config.purchaseReceipt.target > address(0)
                        ? builder.read(config.purchaseReceipt)
                        : builder.balance(config.rwa, config.account),
                    rwa
                );
                builder.check(OP_LESS_OR_EQUAL, layout.minimumRwa, layout.rwaReceived);
            }
        }
        builder.clearApproval(config.usdc, config.issuer, config.purchaseApprovalLeaf);
        recipe = builder.finish();
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
