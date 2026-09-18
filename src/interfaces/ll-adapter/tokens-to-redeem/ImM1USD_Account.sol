// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImM1USD_Account
 * @notice Interface and deployment constants for mM1USD_Account.
 */
abstract contract ImM1USD_Account is IMidasTokenAccount {
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
    address internal constant TOKEN_ADDRESS = 0xCc5C22C7A6BCC25e66726AeF011dDE74289ED203;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x70Ba3211f2584Bf1C8a2aCdF0a00dba559CE1Ffa;
}
