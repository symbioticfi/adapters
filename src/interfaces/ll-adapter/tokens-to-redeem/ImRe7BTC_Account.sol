// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImRe7BTC_Account
 * @notice Interface and deployment constants for mRe7BTC_Account.
 */
abstract contract ImRe7BTC_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 2 days;

    /**
     * @dev Wbtc.
     */
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x9FB442d6B612a6dcD2acC67bb53771eF1D9F661A;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x4Fd4DD7171D14e5bD93025ec35374d2b9b4321b0;
}
