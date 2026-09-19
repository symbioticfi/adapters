// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IRecipeExecutor} from "src/interfaces/periphery/IRecipeExecutor.sol";

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
    }

    struct Limits {
        uint256 maxSupplyLbtc;
        uint256 maxTotalDebtUsdc;
        // Minimum whole RWA tokens per whole USDC, scaled by 1e18; 0.99e18 permits a 1% output shortfall to par.
        uint256 minRwaPerUsdcWad;
    }

    /**
     * @notice Named result registers also identifying runtime slots for approval and managed calls.
     */
    enum Register {
        One,
        UsdcUnit,
        SupplyAmount,
        BorrowAmount,
        MaxSupply,
        MaxDebt,
        MinimumRate,
        RequireSupplyPositive,
        RequireBorrowPositive,
        RequireSupplyLimit,
        LbtcBefore,
        ReceiptBefore,
        UsdcBefore,
        DebtBefore,
        RwaBefore,
        DebtHeadroom,
        RequireDebtHeadroom,
        ApproveLbtc,
        SupplyCall,
        LbtcAfter,
        LbtcSpent,
        RequireLbtcSpent,
        ReceiptAfter,
        ReceiptReceived,
        MaximumReceipt,
        ReceiptWithTolerance,
        RequireReceiptUpperBound,
        RequireReceiptLowerBound,
        BorrowCall,
        UsdcFunded,
        BorrowedUsdc,
        RequireBorrowedUsdc,
        DebtAfter,
        DebtIncrease,
        MaximumDebtIncrease,
        DebtIncreaseWithTolerance,
        RequireDebtUpperBound,
        RequireDebtLowerBound,
        RequireTotalDebt,
        ApproveUsdc,
        PurchaseCall,
        UsdcAfter,
        RequireUsdcPreserved,
        RwaAfter,
        RwaReceived,
        MinimumRwa,
        RequireRwaOutput,
        Zero,
        ClearLbtcApproval,
        ClearUsdcApproval,
        Length
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Returns the curator-configured steps, including fixed limits and state queries.
     */
    function build(Config memory config, Limits memory limits)
        internal
        pure
        returns (IRecipeExecutor.Step[] memory recipe)
    {
        recipe = new IRecipeExecutor.Step[](uint256(Register.Length));
        recipe[uint256(Register.One)] = _literal(IRecipeExecutor.Operation.Constant, 1);
        recipe[uint256(Register.UsdcUnit)] = _literal(IRecipeExecutor.Operation.Constant, 1e6);
        recipe[uint256(Register.SupplyAmount)] = _literal(IRecipeExecutor.Operation.Input, 0);
        recipe[uint256(Register.BorrowAmount)] = _literal(IRecipeExecutor.Operation.Input, 1);
        recipe[uint256(Register.MaxSupply)] = _literal(IRecipeExecutor.Operation.Constant, limits.maxSupplyLbtc);
        recipe[uint256(Register.MaxDebt)] = _literal(IRecipeExecutor.Operation.Constant, limits.maxTotalDebtUsdc);
        recipe[uint256(Register.MinimumRate)] = _literal(IRecipeExecutor.Operation.Constant, limits.minRwaPerUsdcWad);
        recipe[uint256(Register.RequireSupplyPositive)] =
            _binary(IRecipeExecutor.Operation.LessOrEqual, Register.One, Register.SupplyAmount);
        recipe[uint256(Register.RequireBorrowPositive)] =
            _binary(IRecipeExecutor.Operation.LessOrEqual, Register.One, Register.BorrowAmount);
        recipe[uint256(Register.RequireSupplyLimit)] =
            _binary(IRecipeExecutor.Operation.LessOrEqual, Register.SupplyAmount, Register.MaxSupply);

        recipe[uint256(Register.LbtcBefore)] = _balance(config.lbtc, config.adapter);
        recipe[uint256(Register.ReceiptBefore)] = _balance(config.collateralReceipt, config.adapter);
        recipe[uint256(Register.UsdcBefore)] = _balance(config.usdc, config.adapter);
        recipe[uint256(Register.DebtBefore)] = _balance(config.variableDebt, config.adapter);
        recipe[uint256(Register.RwaBefore)] = _balance(config.rwa, config.adapter);
        recipe[uint256(Register.DebtHeadroom)] =
            _binary(IRecipeExecutor.Operation.Subtract, Register.MaxDebt, Register.DebtBefore);
        recipe[uint256(Register.RequireDebtHeadroom)] =
            _binary(IRecipeExecutor.Operation.LessOrEqual, Register.BorrowAmount, Register.DebtHeadroom);

        recipe[uint256(Register.ApproveLbtc)] =
            _approve(Register.SupplyAmount, config.lbtc, config.pool, config.collateralApprovalLeaf);
        recipe[uint256(Register.SupplyCall)] = _manage(config.supplyLeaf);
        recipe[uint256(Register.LbtcAfter)] = _balance(config.lbtc, config.adapter);
        recipe[uint256(Register.LbtcSpent)] =
            _binary(IRecipeExecutor.Operation.Subtract, Register.LbtcBefore, Register.LbtcAfter);
        recipe[uint256(Register.RequireLbtcSpent)] =
            _binary(IRecipeExecutor.Operation.Equal, Register.LbtcSpent, Register.SupplyAmount);
        recipe[uint256(Register.ReceiptAfter)] = _balance(config.collateralReceipt, config.adapter);
        recipe[uint256(Register.ReceiptReceived)] =
            _binary(IRecipeExecutor.Operation.Subtract, Register.ReceiptAfter, Register.ReceiptBefore);
        recipe[uint256(Register.MaximumReceipt)] =
            _binary(IRecipeExecutor.Operation.Add, Register.LbtcSpent, Register.One);
        recipe[uint256(Register.ReceiptWithTolerance)] =
            _binary(IRecipeExecutor.Operation.Add, Register.ReceiptReceived, Register.One);
        recipe[uint256(Register.RequireReceiptUpperBound)] =
            _binary(IRecipeExecutor.Operation.LessOrEqual, Register.ReceiptReceived, Register.MaximumReceipt);
        recipe[uint256(Register.RequireReceiptLowerBound)] =
            _binary(IRecipeExecutor.Operation.LessOrEqual, Register.LbtcSpent, Register.ReceiptWithTolerance);

        recipe[uint256(Register.BorrowCall)] = _manage(config.borrowLeaf);
        recipe[uint256(Register.UsdcFunded)] = _balance(config.usdc, config.adapter);
        recipe[uint256(Register.BorrowedUsdc)] =
            _binary(IRecipeExecutor.Operation.Subtract, Register.UsdcFunded, Register.UsdcBefore);
        recipe[uint256(Register.RequireBorrowedUsdc)] =
            _binary(IRecipeExecutor.Operation.Equal, Register.BorrowedUsdc, Register.BorrowAmount);
        recipe[uint256(Register.DebtAfter)] = _balance(config.variableDebt, config.adapter);
        recipe[uint256(Register.DebtIncrease)] =
            _binary(IRecipeExecutor.Operation.Subtract, Register.DebtAfter, Register.DebtBefore);
        recipe[uint256(Register.MaximumDebtIncrease)] =
            _binary(IRecipeExecutor.Operation.Add, Register.BorrowedUsdc, Register.One);
        recipe[uint256(Register.DebtIncreaseWithTolerance)] =
            _binary(IRecipeExecutor.Operation.Add, Register.DebtIncrease, Register.One);
        recipe[uint256(Register.RequireDebtUpperBound)] =
            _binary(IRecipeExecutor.Operation.LessOrEqual, Register.DebtIncrease, Register.MaximumDebtIncrease);
        recipe[uint256(Register.RequireDebtLowerBound)] =
            _binary(IRecipeExecutor.Operation.LessOrEqual, Register.BorrowedUsdc, Register.DebtIncreaseWithTolerance);
        recipe[uint256(Register.RequireTotalDebt)] =
            _binary(IRecipeExecutor.Operation.LessOrEqual, Register.DebtAfter, Register.MaxDebt);

        recipe[uint256(Register.ApproveUsdc)] =
            _approve(Register.BorrowedUsdc, config.usdc, config.issuer, config.purchaseApprovalLeaf);
        recipe[uint256(Register.PurchaseCall)] = _manage(config.purchaseLeaf);
        recipe[uint256(Register.UsdcAfter)] = _balance(config.usdc, config.adapter);
        recipe[uint256(Register.RequireUsdcPreserved)] =
            _binary(IRecipeExecutor.Operation.Equal, Register.UsdcAfter, Register.UsdcBefore);
        recipe[uint256(Register.RwaAfter)] = _balance(config.rwa, config.adapter);
        recipe[uint256(Register.RwaReceived)] =
            _binary(IRecipeExecutor.Operation.Subtract, Register.RwaAfter, Register.RwaBefore);
        recipe[uint256(Register.MinimumRwa)] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.MulDiv,
            uint256(Register.BorrowedUsdc),
            uint256(Register.MinimumRate),
            uint256(Register.UsdcUnit),
            ""
        );
        recipe[uint256(Register.RequireRwaOutput)] =
            _binary(IRecipeExecutor.Operation.LessOrEqual, Register.MinimumRwa, Register.RwaReceived);

        recipe[uint256(Register.Zero)] = _literal(IRecipeExecutor.Operation.Constant, 0);
        recipe[uint256(Register.ClearLbtcApproval)] =
            _approve(Register.Zero, config.lbtc, config.pool, config.collateralApprovalLeaf);
        recipe[uint256(Register.ClearUsdcApproval)] =
            _approve(Register.Zero, config.usdc, config.issuer, config.purchaseApprovalLeaf);
    }

    function _literal(IRecipeExecutor.Operation operation, uint256 value)
        private
        pure
        returns (IRecipeExecutor.Step memory)
    {
        return IRecipeExecutor.Step(operation, value, 0, 0, "");
    }

    function _binary(IRecipeExecutor.Operation operation, Register a, Register b)
        private
        pure
        returns (IRecipeExecutor.Step memory)
    {
        return IRecipeExecutor.Step(operation, uint256(a), uint256(b), 0, "");
    }

    function _balance(address token, address account) private pure returns (IRecipeExecutor.Step memory) {
        return IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Read, 0, 0, 0, abi.encode(token, abi.encodeCall(IERC20.balanceOf, (account)))
        );
    }

    function _approve(Register amount, address token, address spender, bytes32 leaf)
        private
        pure
        returns (IRecipeExecutor.Step memory)
    {
        return IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Approve, uint256(amount), 0, 0, abi.encode(token, spender, leaf)
        );
    }

    function _manage(bytes32 leaf) private pure returns (IRecipeExecutor.Step memory) {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        return IRecipeExecutor.Step(IRecipeExecutor.Operation.Manage, uint256(Register.One), 0, 0, abi.encode(leaves));
    }
}
