// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAsyncRedeemAccount} from "../IAsyncRedeemAccount.sol";

/**
 * @title IACRDX_Account
 * @notice Interface and deployment constants for ACRDX_Account.
 */
abstract contract IACRDX_Account is IAsyncRedeemAccount {
    /* CONSTANTS */

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x9477724Bb54AD5417de8Baff29e59DF3fB4DA74f;

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 0;
}
