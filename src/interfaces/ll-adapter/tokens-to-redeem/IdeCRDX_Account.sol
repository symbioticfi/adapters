// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAsyncRedeemAccount} from "../IAsyncRedeemAccount.sol";

/**
 * @title IdeCRDX_Account
 * @notice Interface and deployment constants for deCRDX_Account.
 */
abstract contract IdeCRDX_Account is IAsyncRedeemAccount {
    /* CONSTANTS */

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x9E2679eABFF131b8b1b48fF7566140794E0eEdc4;

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 0;
}
