// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ISpikoAccount} from "../spiko/ISpikoAccount.sol";

/**
 * @title ISPKCC_Account
 * @notice Interface and deployment constants for SPKCC_Account.
 */
abstract contract ISPKCC_Account is ISpikoAccount {
    /* CONSTANTS */

    /**
     * @dev Min price.
     */
    uint256 internal constant MIN_PRICE = 0.5e18;

    /**
     * @dev Max price.
     */
    uint256 internal constant MAX_PRICE = 2e18;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x4f33aCf823E6eEb697180d553cE0c710124C8D59;

    /**
     * @dev Redemption address.
     */
    address internal constant REDEMPTION_ADDRESS = 0xDA5599f04e9b437C8394b0c2BC68B502A66ebFe8;

    /**
     * @dev Settlement token address.
     */
    address internal constant SETTLEMENT_TOKEN_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /**
     * @dev Nav feed address.
     */
    address internal constant NAV_FEED_ADDRESS = 0x9e37DBF40fE5Fe9320E45fe6B95b000aa05459A9;

    /**
     * @dev Feed staleness duration.
     */
    uint48 internal constant FEED_STALENESS_DURATION = 30 hours;

    /**
     * @dev Token settlement duration.
     */
    uint48 internal constant TOKEN_SETTLEMENT_DURATION = 30 days;
}
