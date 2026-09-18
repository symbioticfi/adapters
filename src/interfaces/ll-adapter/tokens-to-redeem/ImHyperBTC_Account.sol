// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImHyperBTC_Account
 * @notice Interface and deployment constants for mHyperBTC_Account.
 */
abstract contract ImHyperBTC_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 1 days;

    /**
     * @dev Cbbtc.
     */
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0xC8495EAFf71D3A563b906295fCF2f685b1783085;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x16d4f955B0aA1b1570Fe3e9bB2f8c19C407cdb67;
}
