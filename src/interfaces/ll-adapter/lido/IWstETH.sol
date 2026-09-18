// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IWstETH
 * @notice Interface for minimal Lido wstETH interface used by liquidity lane accounts.
 */
interface IWstETH {
    /* FUNCTIONS */

    /**
     * @notice Wraps stETH into wstETH.
     * @param stETHAmount The stETH amount.
     * @return wstETHAmount The resulting wstETH amount.
     */
    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount);

    /**
     * @notice Unwraps wstETH into stETH.
     * @param wstETHAmount The wstETH amount.
     * @return stETHAmount The resulting stETH amount.
     */
    function unwrap(uint256 wstETHAmount) external returns (uint256 stETHAmount);

    /**
     * @notice Returns the wstETH amount represented by a stETH amount.
     * @param stETHAmount The stETH amount.
     * @return wstETHAmount The resulting wstETH amount.
     */
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256 wstETHAmount);

    /**
     * @notice Returns the stETH amount represented by a wstETH amount.
     * @param wstETHAmount The wstETH amount.
     * @return stETHAmount The resulting stETH amount.
     */
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256 stETHAmount);
}
