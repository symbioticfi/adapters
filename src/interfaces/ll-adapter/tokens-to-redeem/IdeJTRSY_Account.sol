// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAsyncRedeemAccount} from "../IAsyncRedeemAccount.sol";

/**
 * @title IdeJTRSY_Account
 * @notice Interface and deployment constants for deJTRSY_Account.
 */
abstract contract IdeJTRSY_Account is IAsyncRedeemAccount {
    /* CONSTANTS */

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0xA6233014B9b7aaa74f38fa1977ffC7A89642dC72;

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 0;
}
