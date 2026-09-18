// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAsyncRedeemAccount} from "../IAsyncRedeemAccount.sol";

/**
 * @title IJTRSY_Account
 * @notice Interface and deployment constants for JTRSY_Account.
 */
abstract contract IJTRSY_Account is IAsyncRedeemAccount {
    /* CONSTANTS */

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x8c213ee79581Ff4984583C6a801e5263418C4b86;

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 0;
}
