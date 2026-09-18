// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title IStockMarketTRBasisTrade_Account
 * @notice Interface and deployment constants for StockMarketTRBasisTrade_Account.
 */
abstract contract IStockMarketTRBasisTrade_Account is IMidasTokenAccount {
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
    address internal constant TOKEN_ADDRESS = 0x827Ce7E8e35861D9Ac7fE002755767b695A5594a;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x85A7A5FFf71EaEF79e76730F2E717A04aADea27B;
}
