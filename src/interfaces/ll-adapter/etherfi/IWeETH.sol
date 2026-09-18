// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IWeETH
 * @notice Interface for minimal ether.fi weETH interface used by liquidity lane accounts.
 */
interface IWeETH {
    /* FUNCTIONS */

    /**
     * @notice Unwraps weETH into eETH.
     * @param weETHAmount The weETH amount.
     * @return eETHAmount The resulting eETH amount.
     */
    function unwrap(uint256 weETHAmount) external returns (uint256 eETHAmount);

    /**
     * @notice Returns the eETH amount represented by a weETH amount.
     * @param weETHAmount The weETH amount.
     * @return eETHAmount The resulting eETH amount.
     */
    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256 eETHAmount);
}
