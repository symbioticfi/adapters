// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFigureAccount} from "../figure/IFigureAccount.sol";

/**
 * @title IAUTO_Account
 * @notice Interface and deployment constants for AUTO_Account.
 */
abstract contract IAUTO_Account is IFigureAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 1 days;
}
