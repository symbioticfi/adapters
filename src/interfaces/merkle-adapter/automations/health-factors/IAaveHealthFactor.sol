// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IAaveHealthFactor
 * @notice Interface for querying the liquidation health factor of an Aave V3 account.
 */
interface IAaveHealthFactor {
    /* FUNCTIONS */

    /**
     * @notice Returns the account's liquidation health factor scaled by 1e18.
     * @dev Supports the Aave V3 Pool tuple only, reading its sixth value at byte offset 160.
     * Aave V4 Spoke has a different layout and must not be used with this helper.
     * Query the MerkleAccount or actual debt-owning subaccount, not the adapter.
     * Preserves the pool's precision and zero-debt behavior.
     * Native query errors and malformed responses revert.
     * @param pool Aave pool whose account data is queried.
     * @param account Account whose aggregate collateral and debt are queried.
     * @return healthFactor Pool-reported health factor, including type(uint256).max when there is no debt.
     */
    function getHealthFactor(address pool, address account) external view returns (uint256 healthFactor);
}

/**
 * @title IAaveHealthPool
 * @notice Interface for the Aave V3 Pool account data used by the health-factor helper.
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
