// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAccount} from "../IAccount.sol";

/**
 * @title IUSD3_Account
 * @notice Interface and deployment constants for USD3_Account.
 */
abstract contract IUSD3_Account is IAccount {
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
    address internal constant TOKEN_ADDRESS = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
}
