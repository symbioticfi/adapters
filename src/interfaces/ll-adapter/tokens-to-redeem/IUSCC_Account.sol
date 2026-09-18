// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISuperstateAccount} from "../superstate/ISuperstateAccount.sol";

/**
 * @title IUSCC_Account
 * @notice Interface and deployment constants for USCC_Account.
 */
abstract contract IUSCC_Account is ISuperstateAccount {
    /* CONSTANTS */

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x14d60E7FDC0D71d8611742720E4C50E7a974020c;

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 12 hours;

    /**
     * @dev Token settlement duration.
     */
    uint48 internal constant TOKEN_SETTLEMENT_DURATION = 3 days;
}
