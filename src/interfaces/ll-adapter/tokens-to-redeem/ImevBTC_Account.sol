// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImevBTC_Account
 * @notice Interface and deployment constants for mevBTC_Account.
 */
abstract contract ImevBTC_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 1 days;

    /**
     * @dev Wbtc.
     */
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0xb64C014307622eB15046C66fF71D04258F5963DC;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x2d7d5b1706653796602617350571B3F8999B950c;
}
