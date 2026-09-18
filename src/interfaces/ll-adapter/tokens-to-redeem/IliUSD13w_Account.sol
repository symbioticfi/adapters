// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInfiniFiAccount} from "../infinifi/IInfiniFiAccount.sol";

/**
 * @title IliUSD13w_Account
 * @notice Interface and deployment constants for liUSD13w_Account.
 */
abstract contract IliUSD13w_Account is IInfiniFiAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 7 days;

    /**
     * @dev The bucket feed reports `updatedAt = block.timestamp` on every read, so any positive
     * staleness duration passes; 30 days is a generous formality.
     */
    uint48 internal constant FEED_STALENESS_DURATION = 30 days;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0xbd3f9814eB946E617f1d774A6762cDbec0bf087A;

    /**
     * @dev Bucket feed address.
     */
    address internal constant BUCKET_FEED_ADDRESS = 0x8D5FFAa15730D87C90C34A4c2e80684043704417;

    /**
     * @dev Gateway address.
     */
    address internal constant GATEWAY_ADDRESS = 0x3f04b65Ddbd87f9CE0A2e7Eb24d80e7fb87625b5;

    /**
     * @dev Unwinding module address.
     */
    address internal constant UNWINDING_MODULE_ADDRESS = 0x7092A43aE5407666C78dBEA657a1891f42b3dFcc;

    /**
     * @dev Iusd address.
     */
    address internal constant IUSD_ADDRESS = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c;

    /**
     * @dev Unwinding epochs 13w.
     */
    uint32 internal constant UNWINDING_EPOCHS_13W = 13;
}
