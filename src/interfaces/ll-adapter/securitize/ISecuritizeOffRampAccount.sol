// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAccount} from "../IAccount.sol";

/**
 * @title ISecuritizeOffRampAccount
 * @notice Interface for synchronous Securitize off-ramp accounts.
 */
interface ISecuritizeOffRampAccount is IAccount {
    /* ERRORS */

    /**
     * @notice Raised when the off-ramp delivers less than its accepted quote.
     */
    error InsufficientOutput();

    /**
     * @notice Raised when the off-ramp quote is below the independent oracle value.
     */
    error InsufficientQuote();

    /**
     * @notice Raised when the vault asset or current off-ramp output token is invalid.
     */
    error InvalidAsset();

    /**
     * @notice Raised when the current off-ramp input token is invalid.
     */
    error InvalidTokenToRedeem();

    /* FUNCTIONS */

    /**
     * @notice Returns the Securitize off-ramp.
     * @return offRamp The off-ramp address.
     */
    function OFF_RAMP() external view returns (address offRamp);

    /**
     * @notice Returns the off-ramp output token required as the vault asset.
     * @return redemptionToken The redemption-token address.
     */
    function REDEMPTION_TOKEN() external view returns (address redemptionToken);
}
