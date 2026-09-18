// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDigiFTAccount} from "../digift/IDigiFTAccount.sol";

/**
 * @title IbEQTY_Account
 * @notice Interface and deployment constants for bEQTY_Account.
 */
abstract contract IbEQTY_Account is IDigiFTAccount {
    /* CONSTANTS */

    /**
     * @dev Sub red management address.
     */
    address internal constant SUB_RED_MANAGEMENT_ADDRESS = 0x3797C46db697c24a983222c335F17Ba28e8c5b69;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0xEaFD6D38f41f882BCFd5fEaABccCc714B983b701;

    /**
     * @dev Token settlement duration.
     */
    uint48 internal constant TOKEN_SETTLEMENT_DURATION = 7 days;
}
