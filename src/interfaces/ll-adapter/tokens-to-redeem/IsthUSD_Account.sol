// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ITheoAccount} from "../theo/ITheoAccount.sol";

/**
 * @title IsthUSD_Account
 * @notice Interface and deployment constants for sthUSD_Account.
 */
abstract contract IsthUSD_Account is ITheoAccount {
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
    address internal constant TOKEN_ADDRESS = 0xA808Bc9775cb41c52C7842f8b50427fE7A770326;
}
