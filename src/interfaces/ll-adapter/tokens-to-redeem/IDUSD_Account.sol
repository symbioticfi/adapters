// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMakinaAccount} from "../makina/IMakinaAccount.sol";

/**
 * @title IDUSD_Account
 * @notice Interface and deployment constants for DUSD_Account.
 */
abstract contract IDUSD_Account is IMakinaAccount {
    /* CONSTANTS */

    /**
     * @dev Share price oracle address.
     */
    address internal constant SHARE_PRICE_ORACLE_ADDRESS = 0xFFCBc7A7eEF2796C277095C66067aC749f4cA078;

    /**
     * @dev Machine address.
     */
    address internal constant MACHINE_ADDRESS = 0x6b006870C83b1Cd49E766Ac9209f8d68763Df721;

    /**
     * @dev Redeemer address.
     */
    address internal constant REDEEMER_ADDRESS = 0x1303c26cFE06bac5bfEE29907f37919643DEF75c;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x1e33E98aF620F1D563fcD3cfd3C75acE841204ef;

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 72 minutes;

    /**
     * @dev Local fail-closed policy for Makina's global accounting updates.
     */
    uint48 internal constant ORACLE_STALENESS_DURATION = 48 hours;
}
