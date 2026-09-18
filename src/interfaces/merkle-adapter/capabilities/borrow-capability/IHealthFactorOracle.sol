// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IHealthFactorOracle
 * @notice Read interface for Morpho's collateral-to-loan-token oracle.
 */
interface IHealthFactorOracle {
    /* FUNCTIONS */

    /**
     * @notice Returns loan-token units per collateral-token unit, scaled by 1e36.
     */
    function price() external view returns (uint256);
}
