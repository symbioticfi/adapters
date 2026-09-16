// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IFigureSubAccount
 * @notice Interface for a Figure redemption request holder.
 */
interface IFigureSubAccount {
    /* FUNCTIONS */

    /**
     * @notice Initializes the request holder and submits its entire wYLDS balance for redemption.
     * @dev Callable once. The caller receives an unlimited allowance for the redemption asset so it
     * can collect proceeds after the Figure vault processes the request.
     */
    function initialize() external;
}
