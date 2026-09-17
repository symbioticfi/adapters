// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IMorphoBlueHealthFactor
 * @notice Interface for querying the liquidation health factor of the Morpho Blue market.
 */
interface IMorphoBlueHealthFactor {
    /* ERRORS */

    /**
     * @notice Raised when the Morpho Blue market has not been created.
     */
    error InvalidMarket();

    /* FUNCTIONS */

    /**
     * @notice Returns the liquidation health factor scaled by 1e18, rounded down.
     * @dev Includes pending interest, rounds debt up and collateral capacity down. Reverts for an uncreated market.
     * Returns type(uint256).max when there is no debt. Query and oracle failures revert.
     * @param morpho Morpho Blue contract.
     * @param marketId Market identifier.
     * @param account Borrower whose position is queried.
     * @return healthFactor Risk-adjusted collateral value divided by debt value, scaled by 1e18.
     */
    function getHealthFactor(address morpho, bytes32 marketId, address account)
        external
        view
        returns (uint256 healthFactor);
}
