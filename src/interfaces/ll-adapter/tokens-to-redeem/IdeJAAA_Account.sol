// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAsyncRedeemAccount} from "../IAsyncRedeemAccount.sol";

/**
 * @title IdeJAAA_Account
 * @notice Interface and deployment constants for deJAAA_Account.
 */
abstract contract IdeJAAA_Account is IAsyncRedeemAccount {
    /* CONSTANTS */

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0xAAA0008C8CF3A7Dca931adaF04336A5D808C82Cc;

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 0;
}
