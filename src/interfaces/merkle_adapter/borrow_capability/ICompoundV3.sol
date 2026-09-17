// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ICompoundV3
 * @notice Read interface for Compound III collateral and current debt.
 */
interface ICompoundV3 {
    /* STRUCTS */

    /**
     * @notice Collateral configuration in Comet's ABI order.
     * @param offset Index in the collateral bitmap.
     * @param asset Collateral ERC-20.
     * @param priceFeed Collateral price feed.
     * @param scale Collateral token unit.
     * @param borrowCollateralFactor Borrowing collateral factor scaled by 1e18.
     * @param liquidateCollateralFactor Liquidation collateral factor scaled by 1e18.
     * @param liquidationFactor Liquidation penalty factor scaled by 1e18.
     * @param supplyCap Collateral supply cap.
     */
    struct AssetInfo {
        uint8 offset;
        address asset;
        address priceFeed;
        uint64 scale;
        uint64 borrowCollateralFactor;
        uint64 liquidateCollateralFactor;
        uint64 liquidationFactor;
        uint128 supplyCap;
    }

    /* FUNCTIONS */

    /**
     * @notice Returns the current debt including pending interest, in base-token units.
     */
    function borrowBalanceOf(address account) external view returns (uint256);

    /**
     * @notice Returns the base token's price feed.
     */
    function baseTokenPriceFeed() external view returns (address);

    /**
     * @notice Returns the base token unit.
     */
    function baseScale() external view returns (uint256);

    /**
     * @notice Returns the number of supported collateral assets.
     */
    function numAssets() external view returns (uint8);

    /**
     * @notice Returns the collateral configuration at the supplied index.
     */
    function getAssetInfo(uint8 index) external view returns (AssetInfo memory);

    /**
     * @notice Returns the account's supplied collateral balance.
     */
    function collateralBalanceOf(address account, address asset) external view returns (uint128);

    /**
     * @notice Returns the feed price in Comet's common price scale; invalid prices revert.
     */
    function getPrice(address priceFeed) external view returns (uint256);
}
