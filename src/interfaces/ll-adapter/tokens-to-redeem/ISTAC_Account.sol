// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISecuritizeNoticeAccount} from "../securitize/ISecuritizeNoticeAccount.sol";

/**
 * @title ISTAC_Account
 * @notice Interface and deployment constants for STAC_Account.
 */
abstract contract ISTAC_Account is ISecuritizeNoticeAccount {
    /* CONSTANTS */

    /**
     * @dev Min price.
     */
    uint256 internal constant MIN_PRICE = 100e18;

    /**
     * @dev Max price.
     */
    uint256 internal constant MAX_PRICE = 10_000e18;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x51C2d74017390CbBd30550179A16A1c28F7210fc;

    /**
     * @dev Redemption wallet address.
     */
    address internal constant REDEMPTION_WALLET_ADDRESS = 0xbb543C77436645C8b95B64eEc39E3C0d48D4842b;

    /**
     * @dev Nav feed address.
     */
    address internal constant NAV_FEED_ADDRESS = 0xEdC6287D3D41b322AF600317628D7E226DD3add4;

    /**
     * @dev Feed staleness duration.
     */
    uint48 internal constant FEED_STALENESS_DURATION = 30 hours;

    /**
     * @dev Token settlement duration.
     */
    uint48 internal constant TOKEN_SETTLEMENT_DURATION = 30 days;
}
