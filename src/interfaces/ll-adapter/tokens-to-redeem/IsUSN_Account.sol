// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {INoonAccount} from "../noon/INoonAccount.sol";

/**
 * @title IsUSN_Account
 * @notice Interface and deployment constants for sUSN_Account.
 */
abstract contract IsUSN_Account is INoonAccount {
    /* CONSTANTS */

    /**
     * @dev Min price.
     */
    uint256 internal constant MIN_PRICE = 0.5e18;

    /**
     * @dev Max price.
     */
    uint256 internal constant MAX_PRICE = 2.5e18;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0xE24a3DC889621612422A64E6388927901608B91D;

    /**
     * @dev Withdrawal handler address.
     */
    address internal constant WITHDRAWAL_HANDLER_ADDRESS = 0x0DaBc0D9B270c9B0C4C77AaCeAa712b56D0F9178;

    /**
     * @dev Rate provider address.
     */
    address internal constant RATE_PROVIDER_ADDRESS = 0x7f741401422Afff770360fD13127F7462C6E1A79;

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 17 hours;
}
