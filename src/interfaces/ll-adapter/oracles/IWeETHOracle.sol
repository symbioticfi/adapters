// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle} from "../IOracle.sol";

/**
 * @title IWeETHOracle
 * @notice Interface for the native weETH-to-eETH rate oracle.
 */
interface IWeETHOracle is IOracle {
    /* FUNCTIONS */

    /**
     * @notice Returns the weETH token used as the rate source.
     * @return weETH The weETH token address.
     */
    function WEETH() external view returns (address weETH);
}
