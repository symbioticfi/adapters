// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMulticallable} from "@symbioticfi/core/src/interfaces/common/IMulticallable.sol";

/**
 * @dev Precision for request yield ratios; 1e8 represents 100%.
 */
uint256 constant YIELD_PRECISION = 1e8;

/**
 * @title IThreeFPolicy
 * @notice Interface for per-asset funding budgets and minimum request yield charged by one consumer.
 */
interface IThreeFPolicy is IMigratableEntity, IMulticallable {
    /* ERRORS */

    /**
     * @notice Raised when the charged principal is zero.
     */
    error InvalidAssets();

    /**
     * @notice Raised when someone other than the current consumer consumes the budget.
     */
    error InvalidCaller();

    /**
     * @notice Raised when the request yield is below the curator's minimum.
     */
    error TooLowYield();

    /* EVENTS */

    /**
     * @notice Emitted when the owner changes a collateral asset's budget in funding-token base units.
     */
    event SetMaxAssetsPerDuration(address indexed asset, uint256 maxAssets, uint48 duration);

    /**
     * @notice Emitted when the consumer is initialized or changed.
     */
    event SetConsumer(address indexed consumer);
    /**
     * @notice Emitted when the owner changes an asset's minimum yield per unit of principal, scaled by 1e8.
     */
    event SetMinYieldPerRequest(address indexed asset, uint256 minimum);
    /**
     * @notice Emitted when the consumer charges principal to an asset's current period.
     */
    event Consume(address indexed asset, uint256 assets);

    /* FUNCTIONS */

    /**
     * @notice Returns an asset's budget and last recorded usage; expired usage is reset lazily.
     * @dev Use remainingAssets to obtain the current spendable budget.
     * @param asset Collateral underlying whose budget is queried.
     * @return maxAssets Funding-token base units allowed in each period.
     * @return duration Period length in seconds.
     * @return periodStart Start of the last recorded period.
     * @return spent Funding-token base units consumed in that period.
     */
    function assetLimits(address asset)
        external
        view
        returns (uint256 maxAssets, uint48 duration, uint48 periodStart, uint256 spent);

    /**
     * @notice Returns the current spendable budget in funding-token base units; zero if disabled or unconfigured.
     */
    function remainingAssets(address asset) external view returns (uint256 assets);

    /**
     * @notice Sets a collateral asset's budget; only the owner may call and duration must be nonzero.
     * @dev Reconfiguration preserves usage in an active period. Changing duration starts a new period
     * at the current timestamp and carries that usage forward. Zero maxAssets disables spending
     * without erasing usage. Unused capacity never carries into another period.
     * @param asset Collateral underlying whose budget is configured.
     * @param newMaxAssets Funding-token base units allowed in each period; zero disables spending.
     * @param newDuration Period length in seconds.
     */
    function setMaxAssetsPerDuration(address asset, uint256 newMaxAssets, uint48 newDuration) external;

    /**
     * @notice Returns the sole address allowed to consume this policy's budgets.
     * @dev Set by `initialize` through the factory, from `abi.encode(consumer)`; zero leaves the
     * policy inert until the owner points it somewhere. Budgets and minimums are configured
     * afterwards and survive migration along with the current period's usage.
     */
    function consumer() external view returns (address);
    /**
     * @notice Returns an asset's minimum yield/principal ratio, scaled by 1e8; this is not annualized.
     */
    function minYieldPerRequest(address asset) external view returns (uint256);
    /**
     * @notice Moves the budget to another consumer; owner-only, zero disables all consumption.
     * @dev Use the account for guarded mint leaves, or the executor for direct policy Calls followed
     * by native mint leaves and recipe checks. A policy has one consumer at a time; repointing
     * preserves usage and immediately blocks the previous consumer. Direct mint leaf roles must
     * be restricted to the executor to prevent bypassing its recipe's policy. A bare consume leaf
     * charges budget without enforcing an accompanying mint.
     */
    function setConsumer(address newConsumer) external;
    /**
     * @notice Updates an asset's minimum yield immediately; owner-only and independent of the account root.
     */
    function setMinYieldPerRequest(address asset, uint256 newMinimum) external;
    /**
     * @notice Checks the yield and charges principal before minting; only the consumer may call.
     * @dev The caller must enforce these exact amounts. Within a guarded sequence the accompanying
     * checks bind `assets` and `yieldAssets` to the observed principal and yield deltas, so an
     * understated charge reverts. An executor consuming directly must enforce equivalent deltas in
     * its committed recipe. A failed mint must revert the entire transaction. Funding is
     * cumulative: claims do not refund the budget. Repointing the consumer keeps the current
     * period's usage; it grants no fresh budget.
     * @param asset Collateral underlying whose period budget is charged.
     * @param assets Principal in funding-token base units; zero reverts.
     * @param yieldAssets Yield in funding-token base units.
     */
    function consume(address asset, uint256 assets, uint256 yieldAssets) external;
}
