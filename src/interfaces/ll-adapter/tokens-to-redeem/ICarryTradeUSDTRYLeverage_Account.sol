// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ICarryTradeUSDTRYLeverage_Account
 * @notice Interface and deployment constants for CarryTradeUSDTRYLeverage_Account.
 */
abstract contract ICarryTradeUSDTRYLeverage_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 12 hours;

    /**
     * @dev Mainnet usdc.
     */
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x2bf11d2E04Bc40daa95c24B8b90EC4F5c57Dd326;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0xD980df2A697bfd38279BE1Ee2bc13495c101d5C9;
}
