// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IEulerHealthFactor
 * @notice Interface for querying the liquidation health factor of the Euler liability vault.
 */
interface IEulerHealthFactor {
    /* FUNCTIONS */

    /**
     * @notice Returns the liquidation health factor scaled by 1e18, rounded down.
     * @dev Uses liquidation LTVs and liquidation prices from accountLiquidity(account, true). Native query errors are propagated.
     * Returns type(uint256).max when there is no debt. Query and oracle failures revert.
     * @param vault Euler EVK liability vault.
     * @param account EVC account whose position is queried.
     * @return healthFactor Risk-adjusted collateral value divided by debt value, scaled by 1e18.
     */
    function getHealthFactor(address vault, address account) external view returns (uint256 healthFactor);
}
