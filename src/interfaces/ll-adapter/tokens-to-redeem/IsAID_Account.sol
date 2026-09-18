// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IGaibAccount} from "../gaib/IGaibAccount.sol";

/**
 * @title IsAID_Account
 * @notice Interface and deployment constants for sAID_Account.
 */
abstract contract IsAID_Account is IGaibAccount {
    /* CONSTANTS */

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0xB3B3c527BA57cd61648e2EC2F5e006A0B390A9F8;

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 6 days;
}
