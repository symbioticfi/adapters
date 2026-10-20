// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Even user-configuration bits flag borrowed reserves in Aave V3.
 */
uint256 constant AAVE_BORROWING_MASK = 0x5555555555555555555555555555555555555555555555555555555555555555;

/**
 * @title IAaveV3Liquidity
 * @notice Interface for scalar, asset-denominated Aave V3 withdrawal and borrowing queries.
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
     * @notice Returns debt-asset units available under the configured health floor, native LTV, cash and borrow cap.
     * @dev Aave V3.3+ native account data includes eMode thresholds. The debt asset must be borrowable in that category.
     * Unsupported isolation and siloed borrowing return zero.
     * Every conversion rounds down. Health/LTV and borrow-cap debt headroom each reserve one raw debt unit
     * for the recipe's admitted indexed-token rounding. Failed reads revert; the guarded leaf must check final health.
     */
    function maxBorrow(address pool, address asset, address account, uint256 minHealthFactor)
        external
        view
        returns (uint256);

    /**
     * @notice Returns the minimum of the account's aToken balance and Aave's virtual underlying liquidity.
     * @dev Matches AaveV3Adapter liquidity sizing. Does not check debt, health, reserve flags or account modes.
     * Use liquidityWithBorrow for collateral supporting debt. Values are underlying asset units.
     */
    function liquidity(address pool, address asset, address account) external view returns (uint256);

    /**
     * @notice Returns Aave withdrawal capacity preserving protocol solvency at a minimum health factor of 1e18.
     * @dev Unsupported eMode, isolation and siloed positions return zero. Values are underlying asset units.
     * Supply-only accounts use the borrowing bitmap without portfolio valuation or oracle reads.
     * A stricter health floor in an approved leaf may require a smaller amount.
     */
    function liquidityWithBorrow(address pool, address asset, address account) external view returns (uint256);
}
