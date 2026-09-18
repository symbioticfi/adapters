// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISecuritizeAccount} from "../securitize/ISecuritizeAccount.sol";

/**
 * @title IACRED_Account
 * @notice Interface and deployment constants for ACRED_Account.
 */
abstract contract IACRED_Account is ISecuritizeAccount {
    /* CONSTANTS */

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x17418038ecF73BA4026c4f428547BF099706F27B;

    /**
     * @dev Redemption wallet address.
     */
    address internal constant REDEMPTION_WALLET_ADDRESS = 0xbb543C77436645C8b95B64eEc39E3C0d48D4842b;

    /**
     * @dev Token valuation delay.
     */
    uint48 internal constant TOKEN_VALUATION_DELAY = 4 days;

    /**
     * @dev Token post cutoff window.
     */
    uint48 internal constant TOKEN_POST_CUTOFF_WINDOW = 30 days;
}
