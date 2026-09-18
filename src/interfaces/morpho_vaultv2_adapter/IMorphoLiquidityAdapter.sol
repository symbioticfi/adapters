// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IMorphoLiquidityAdapter
 * @notice Interface for minimal Morpho liquidity adapter interface used by the adapter.
 */
interface IMorphoLiquidityAdapter {
    /* FUNCTIONS */

    /**
     * @notice Returns real assets tracked by the liquidity adapter.
     * @return assets Real asset amount.
     */
    function realAssets() external view returns (uint256 assets);
}
