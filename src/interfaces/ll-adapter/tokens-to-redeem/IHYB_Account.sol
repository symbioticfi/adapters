// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAsyncRedeemAccount} from "../IAsyncRedeemAccount.sol";

/**
 * @title IHYB_Account
 * @notice Interface and deployment constants for HYB_Account.
 */
abstract contract IHYB_Account is IAsyncRedeemAccount {
    /* CONSTANTS */

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x4827C7ecce4f07ADfe44A97165f06A199e7d2505;

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 0;
}
