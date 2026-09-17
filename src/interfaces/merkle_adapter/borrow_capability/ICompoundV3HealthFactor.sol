// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ICompoundV3HealthFactor
 * @notice Interface for querying the liquidation health factor of the Compound III market.
 */
interface ICompoundV3HealthFactor {
    /* FUNCTIONS */

    /**
     * @notice Returns the liquidation health factor scaled by 1e18, rounded down.
     * @dev Uses current borrowed assets and liquidation collateral factors. All collateral and debt values use Comet price and token scales.
     * Returns type(uint256).max when debt or its rounded price value is zero. Query and oracle failures revert.
     * @param comet Compound III Comet contract.
     * @param account Borrower whose position is queried.
     * @return healthFactor Risk-adjusted collateral value divided by debt value, scaled by 1e18.
     */
    function getHealthFactor(address comet, address account) external view returns (uint256 healthFactor);
}
