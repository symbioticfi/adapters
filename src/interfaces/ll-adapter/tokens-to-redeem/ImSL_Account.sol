// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImSL_Account
 * @notice Interface and deployment constants for mSL_Account.
 */
abstract contract ImSL_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 1 days;

    /**
     * @dev Mainnet usdc.
     */
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x76CC16608aA7Cd32631bb151801bb095313F7bbd;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x8Bee3870Ad8293dcE79E6f4cb049F7531Bd57c22;
}
