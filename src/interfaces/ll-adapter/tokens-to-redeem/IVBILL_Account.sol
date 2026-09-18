// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISecuritizeOffRampAccount} from "../securitize/ISecuritizeOffRampAccount.sol";

/**
 * @title IVBILL_Account
 * @notice Interface and deployment constants for VBILL_Account.
 */
abstract contract IVBILL_Account is ISecuritizeOffRampAccount {
    /* CONSTANTS */

    /**
     * @dev Min price.
     */
    uint256 internal constant MIN_PRICE = 0.95e18;

    /**
     * @dev Max price.
     */
    uint256 internal constant MAX_PRICE = 1.05e18;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x2255718832bC9fD3bE1CaF75084F4803DA14FF01;

    /**
     * @dev Off ramp address.
     */
    address internal constant OFF_RAMP_ADDRESS = 0x1eD617529d80AE87E6611f11D8de8532ECED42bC;

    /**
     * @dev Settlement token address.
     */
    address internal constant SETTLEMENT_TOKEN_ADDRESS = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;

    /**
     * @dev Nav feed address.
     */
    address internal constant NAV_FEED_ADDRESS = 0xA569E68B5D110F2A255482c2997DFDBe1b2ab912;

    /**
     * @dev Feed staleness duration.
     */
    uint48 internal constant FEED_STALENESS_DURATION = 30 hours;
}
