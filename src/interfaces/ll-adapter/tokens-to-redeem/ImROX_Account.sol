// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImROX_Account
 * @notice Interface and deployment constants for mROX_Account.
 */
abstract contract ImROX_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 6 hours;

    /**
     * @dev Mainnet usdc.
     */
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x67E1F506B148d0Fc95a4E3fFb49068ceB6855c05;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0xc33dAdA688f224c514682Ec6Ba940888d43C4b29;
}
