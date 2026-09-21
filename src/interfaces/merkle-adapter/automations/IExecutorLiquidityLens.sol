// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IExecutorLiquidityLens
 * @notice Interface for scalar, asset-denominated withdrawal liquidity queries for recipe funding sources.
 * @dev Queries are conservative capacities, not promises that a later transaction will succeed.
 * Borrow amounts are selected off-chain; health constraints are enforced by the approved guarded leaves.
 */
interface IExecutorLiquidityLens {
    /* STRUCTS */

    /// @notice Reserve configuration, native-unit scale, price, available cash and aToken rounding allowance.
    struct AaveReserve {
        uint256 configuration;
        uint256 unit;
        uint256 price;
        uint256 cash;
        uint256 incomeRounding;
        address aToken;
    }

    /* FUNCTIONS */

    /**
     * @notice Returns Aave withdrawal capacity preserving protocol solvency at a minimum health factor of 1e18.
     * @dev Unsupported eMode, isolation and siloed positions return zero. Values are underlying asset units.
     * A stricter health floor in an approved leaf may require a smaller amount.
     */
    function aaveWithdraw(address pool, address asset, address account) external view returns (uint256);

    /**
     * @notice Returns Morpho V2 vault withdrawal capacity through its currently configured liquidity adapter.
     */
    function morphoVaultWithdraw(address vault, address account) external view returns (uint256);
}
