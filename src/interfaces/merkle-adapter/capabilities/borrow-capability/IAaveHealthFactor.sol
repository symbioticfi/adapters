// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IAaveHealthFactor
 * @notice Interface for querying the liquidation health factor of an Aave account.
 */
interface IAaveHealthFactor {
    /* FUNCTIONS */

    /**
     * @notice Returns the account's liquidation health factor scaled by 1e18.
     * @dev Returns the sixth value of getUserAccountData without changing its precision or zero-debt behavior.
     * Native query errors and malformed responses revert.
     * @param pool Aave pool whose account data is queried.
     * @param account Account whose aggregate collateral and debt are queried.
     * @return healthFactor Pool-reported health factor, including type(uint256).max when there is no debt.
     */
    function getHealthFactor(address pool, address account) external view returns (uint256 healthFactor);
}

/**
 * @title IAaveHealthPool
 * @notice Interface for the Aave account data used by the health-factor helper.
 */
interface IAaveHealthPool {
    /* FUNCTIONS */

    /**
     * @notice Returns aggregate collateral, debt, available borrowing, liquidation threshold, LTV and health.
     * @param account Account whose lending position is queried.
     * @return totalCollateralBase Total collateral value in the pool's base currency.
     * @return totalDebtBase Total debt value in the pool's base currency.
     * @return availableBorrowsBase Available borrowing value in the pool's base currency.
     * @return currentLiquidationThreshold Weighted liquidation threshold.
     * @return ltv Weighted borrowing loan-to-value ratio.
     * @return healthFactor Liquidation health factor scaled by 1e18.
     */
    function getUserAccountData(address account)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}
