// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IMorphoMidnightHealthFactor
 * @notice Interface for querying the liquidation health factor of the Morpho Midnight market.
 */
interface IMorphoMidnightHealthFactor {
    /* FUNCTIONS */

    /**
     * @notice Returns the liquidation health factor scaled by 1e18, rounded down.
     * @dev Uses activated collateral and face-value debt. Returns zero after maturity when debt remains. Reverts for an untouched market.
     * Returns type(uint256).max when there is no debt. Query and oracle failures revert.
     * @param midnight Midnight contract.
     * @param marketId Market identifier.
     * @param account Borrower whose position is queried.
     * @return healthFactor Risk-adjusted collateral value divided by debt value, scaled by 1e18.
     */
    function getHealthFactor(address midnight, bytes32 marketId, address account)
        external
        view
        returns (uint256 healthFactor);
}
