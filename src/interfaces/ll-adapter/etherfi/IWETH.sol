// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IWETH
 * @notice Interface for minimal WETH interface used by liquidity lane accounts.
 */
interface IWETH {
    /* FUNCTIONS */

    /**
     * @notice Wraps received ETH into WETH.
     */
    function deposit() external payable;
}
