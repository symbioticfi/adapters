// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IAssetRateLimits
 * @notice Interface for per-asset funding budgets configured through curator-authorized adapter calls.
 */
interface IAssetRateLimits {
    /* ERRORS */

    /**
     * @notice Raised when an operation exceeds the remaining asset budget.
     */
    error AssetLimitExceeded();

    /**
     * @notice Raised when a configured period has zero duration.
     */
    error InvalidDuration();

    /**
     * @notice Raised when an asset has no enabled funding budget.
     */
    error UnconfiguredAsset();

    /* STRUCTS */

    /**
     * @notice Funding budget and cumulative usage for one asset's fixed period.
     * @param maxAssets Maximum funding-token base units per period; zero disables spending.
     * @param duration Period length in seconds.
     * @param periodStart Start of the last recorded period.
     * @param spent Funding-token base units spent in that period.
     */
    struct AssetLimit {
        uint256 maxAssets;
        uint256 duration;
        uint256 periodStart;
        uint256 spent;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the curator changes an asset's funding budget.
     * @param asset Collateral underlying for ThreeF, or RWA token for Liquid Lane.
     * @param maxAssets Funding-token base units allowed in each period.
     * @param duration Period length in seconds.
     */
    event SetMaxAssetsPerDuration(address indexed asset, uint256 maxAssets, uint256 duration);

    /* FUNCTIONS */

    /**
     * @notice Returns configuration and usage for an asset; expired usage is reset lazily.
     * @dev Use remainingAssets to obtain the current spendable budget.
     * @param asset Action-specific asset key.
     * @return maxAssets Funding-token base units allowed in each period.
     * @return duration Period length in seconds.
     * @return periodStart Start of the last recorded period.
     * @return spent Funding-token base units consumed in that period.
     */
    function assetLimits(address asset)
        external
        view
        returns (uint256 maxAssets, uint256 duration, uint256 periodStart, uint256 spent);

    /**
     * @notice Returns the funding-token base units available in the current period.
     * @param asset Action-specific asset key.
     * @return assets Remaining budget; zero for an unconfigured or disabled asset.
     */
    function remainingAssets(address asset) external view returns (uint256 assets);

    /**
     * @notice Sets an asset's budget through the bound adapter; duration must be nonzero.
     * @dev Reconfiguration preserves usage in an active period. A duration change starts a new
     * period at the current timestamp and carries that usage forward. Zero maxAssets disables
     * spending without erasing usage. Unused capacity never carries into another period.
     * @param asset Collateral underlying for ThreeF, or configured RWA token for Liquid Lane.
     * @param newMaxAssets Funding-token base units allowed in each period; zero disables the asset.
     * @param newDuration Period length in seconds, starting with the first configuration.
     */
    function setMaxAssetsPerDuration(address asset, uint256 newMaxAssets, uint256 newDuration) external;
}
