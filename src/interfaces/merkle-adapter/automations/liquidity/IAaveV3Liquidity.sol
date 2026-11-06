// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Even user-configuration bits flag borrowed reserves in Aave V3.
 */
uint256 constant AAVE_BORROWING_MASK = 0x5555555555555555555555555555555555555555555555555555555555555555;

/**
 * @title IAaveV3Liquidity
 * @notice Interface for scalar, asset-denominated Aave V3 withdrawal queries.
 * @dev Queries report liquidity bounds, not promises that a later transaction will succeed.
 * Health constraints are also enforced by the approved guarded leaves at execution.
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
     * @notice Returns liquidity capped by needed, or zero without protocol reads when needed is zero.
     * @dev Uses the same supply-only calculation as liquidity(pool, asset, account).
     * Bind needed to the recipe's remaining funding shortfall to preserve source priority.
     * @param needed Maximum required amount in underlying asset units.
     */
    function liquidity(address pool, address asset, address account, uint256 needed) external view returns (uint256);

    /**
     * @notice Returns Aave withdrawal capacity preserving protocol solvency at a minimum health factor of 1e18.
     * @dev Unsupported eMode, isolation and siloed positions return zero. Values are underlying asset units.
     * Supply-only accounts use the borrowing bitmap without portfolio valuation or oracle reads.
     * A stricter health floor in an approved leaf may require a smaller amount.
     */
    function liquidityWithBorrow(address pool, address asset, address account) external view returns (uint256);

    /**
     * @notice Returns debt-aware liquidity capped by needed, or zero without protocol reads when needed is zero.
     * @dev Retains all supported-mode, solvency and rounding checks from liquidityWithBorrow(pool, asset, account).
     * Bind needed to the recipe's remaining funding shortfall to preserve source priority.
     * @param needed Maximum required amount in underlying asset units.
     */
    function liquidityWithBorrow(address pool, address asset, address account, uint256 needed)
        external
        view
        returns (uint256);
}
