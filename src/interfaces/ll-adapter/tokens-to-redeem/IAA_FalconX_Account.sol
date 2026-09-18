// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IParetoAccount} from "../pareto/IParetoAccount.sol";

/**
 * @title IAA_FalconX_Account
 * @notice Interface and deployment constants for AA_FalconX_Account.
 */
abstract contract IAA_FalconX_Account is IParetoAccount {
    /* CONSTANTS */

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C;

    /**
     * @dev Withdrawal queue address.
     */
    address internal constant WITHDRAWAL_QUEUE_ADDRESS = 0x5cC24f44cCAa80DD2c079156753fc1e908F495DC;
}
