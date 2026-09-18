// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImFARM_Account
 * @notice Interface and deployment constants for mFARM_Account.
 */
abstract contract ImFARM_Account is IMidasTokenAccount {
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
    address internal constant TOKEN_ADDRESS = 0xA19f6e0dF08a7917F2F8A33Db66D0AF31fF5ECA6;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0xf4F042D90f0C0d3ABA4A30Caa6Ac124B14A7e600;
}
