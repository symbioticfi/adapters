// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAccount} from "../IAccount.sol";

/**
 * @title IsUSD3_Account
 * @notice Interface and deployment constants for sUSD3_Account.
 */
abstract contract IsUSD3_Account is IAccount {
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
    address internal constant TOKEN_ADDRESS = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;
}
