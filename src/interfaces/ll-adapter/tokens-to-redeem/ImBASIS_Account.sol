// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImBASIS_Account
 * @notice Interface and deployment constants for mBASIS_Account.
 */
abstract contract ImBASIS_Account is IMidasTokenAccount {
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
    address internal constant TOKEN_ADDRESS = 0x2a8c22E3b10036f3AEF5875d04f8441d4188b656;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x19AB19e61A930bc5C7B75Bf06cDd954218Ca9F0b;
}
