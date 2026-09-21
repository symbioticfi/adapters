// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IAaveV3Liquidity
 * @notice Interface for scalar, asset-denominated Aave V3 withdrawal liquidity queries.
 * @dev Queries report liquidity bounds, not promises that a later transaction will succeed.
 * Borrow amounts are selected off-chain; health constraints are enforced by the approved guarded leaves.
 */
interface IAaveV3Liquidity {
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
     * @notice Returns the minimum of the account's aToken balance and Aave's virtual underlying liquidity.
     * @dev Matches AaveV3Adapter liquidity sizing. Does not check debt, health, reserve flags or account modes.
     * Use liquidityWithBorrow for collateral supporting debt. Values are underlying asset units.
     */
    function liquidity(address pool, address asset, address account) external view returns (uint256);

    /**
     * @notice Returns Aave withdrawal capacity preserving protocol solvency at a minimum health factor of 1e18.
     * @dev Unsupported eMode, isolation and siloed positions return zero. Values are underlying asset units.
     * A stricter health floor in an approved leaf may require a smaller amount.
     */
    function liquidityWithBorrow(address pool, address asset, address account) external view returns (uint256);
}
