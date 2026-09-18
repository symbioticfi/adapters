// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImGLOBAL_Account
 * @notice Interface and deployment constants for mGLOBAL_Account.
 */
abstract contract ImGLOBAL_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 12 hours;

    /**
     * @dev Token pre cutoff window.
     */
    uint48 internal constant TOKEN_PRE_CUTOFF_WINDOW = 5 days;

    /**
     * @dev Token initial cutoff.
     */
    uint48 internal constant TOKEN_INITIAL_CUTOFF = 1_785_074_400;

    /**
     * @dev Mainnet usdc.
     */
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x7433806912Eae67919e66aea853d46Fa0aef98A8;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x1e0fd66753198c7b8bA64edEe8d41D8628Bf20D7;
}
