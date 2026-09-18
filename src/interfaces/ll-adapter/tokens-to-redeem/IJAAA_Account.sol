// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAsyncRedeemAccount} from "../IAsyncRedeemAccount.sol";

/**
 * @title IJAAA_Account
 * @notice Interface and deployment constants for JAAA_Account.
 */
abstract contract IJAAA_Account is IAsyncRedeemAccount {
    /* CONSTANTS */

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x5a0F93D040De44e78F251b03c43be9CF317Dcf64;

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 0;
}
