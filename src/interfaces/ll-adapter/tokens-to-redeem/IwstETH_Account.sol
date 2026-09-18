// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILidoAccount} from "../lido/ILidoAccount.sol";

/**
 * @title IwstETH_Account
 * @notice Interface and deployment constants for wstETH_Account.
 */
abstract contract IwstETH_Account is ILidoAccount {
    /* CONSTANTS */

    /**
     * @dev Steth address.
     */
    address internal constant STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /**
     * @dev Weth address.
     */
    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /**
     * @dev Withdrawal queue address.
     */
    address internal constant WITHDRAWAL_QUEUE_ADDRESS = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
}
