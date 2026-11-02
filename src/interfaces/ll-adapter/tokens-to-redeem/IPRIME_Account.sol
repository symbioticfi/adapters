// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IFigureAccount} from "../figure/IFigureAccount.sol";

/**
 * @title IPRIME_Account
 * @notice Interface and deployment constants for PRIME_Account.
 */
abstract contract IPRIME_Account is IFigureAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 18 hours;
}
