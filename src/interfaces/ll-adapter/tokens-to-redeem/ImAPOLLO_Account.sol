// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImAPOLLO_Account
 * @notice Interface and deployment constants for mAPOLLO_Account.
 */
abstract contract ImAPOLLO_Account is IMidasTokenAccount {
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
    address internal constant TOKEN_ADDRESS = 0x7CF9DEC92ca9FD46f8d86e7798B72624Bc116C05;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x5aeA6D35ED7B3B7aE78694B7da2Ee880756Af5C0;
}
