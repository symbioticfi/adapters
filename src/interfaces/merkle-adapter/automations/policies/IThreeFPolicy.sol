// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMulticallable} from "@symbioticfi/core/src/interfaces/common/IMulticallable.sol";

/**
 * @dev Prefix before the request intent id.
 */
bytes8 constant REQUEST_NAME_PREFIX = "request-";

/**
 * @dev Length of the request name prefix.
 */
uint256 constant REQUEST_NAME_PREFIX_LENGTH = 8;

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
     * @notice Raised when the resolved collateral underlying is zero.
     */
    error InvalidAsset();

    /**
     * @notice Raised when the charged principal is zero.
     */
    error InvalidAssets();

    /**
     * @notice Raised when someone other than the current consumer consumes the budget.
     */
    error InvalidCaller();

    /**
     * @notice Raised when a request is not registered by the trusted request factory.
     */
    error InvalidRequest();

    /**
     * @notice Raised when the request name has a missing or incorrect prefix or an empty intent id.
     */
    error InvalidRequestName();

    /**
     * @notice Raised when the facility intent is bound to a different request.
     */
    error RequestMismatch();

    /**
     * @notice Raised when the request yield is below the curator's minimum.
     */
    error TooLowYield();

    /**
     * @notice Raised when the facility intent target is not a position manager.
     */
    error UnsupportedTarget();

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
     * @notice Returns the trusted native 3F request factory pinned by this implementation.
     */
    function REQUESTS_FACTORY() external view returns (address);

    /**
     * @notice Returns the trusted 3F facility pinned by this implementation.
     */
    function FACILITY() external view returns (address);

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
     * @param asset Collateral underlying whose minimum is configured.
     * @param newMinimum Yield/principal ratio scaled by 1e8 (1e8 = 100%, 2_000_000 = 2%); not annualized.
     */
    function setMinYieldPerRequest(address asset, uint256 newMinimum) external;
    /**
     * @notice Validates a request, checks its yield and charges its collateral budget; only the consumer may call.
     * @dev Requires factory membership and a name of the form request-{decimal id}. The facility must bind
     * that id to the same request and identify its target as a position manager. Resolves the manager's
     * collateral through underlying(); zero underlying is rejected. Invalid decimal digits and oversized
     * ids revert through Strings.parseUint, and failed dependency reads bubble their revert data.
     * The caller cannot select another asset's budget. Requests sharing a collateral budget must use the
     * same funding token and denomination; use separate policy instances otherwise.
     * The caller must enforce these exact amounts. Within a guarded sequence the accompanying
     * checks bind `assets` and `yieldAssets` to the observed principal and yield deltas, so an
     * understated charge reverts. An executor consuming directly must enforce equivalent deltas in
     * its committed recipe. A failed mint must revert the entire transaction. Funding is
     * cumulative: claims do not refund the budget. Repointing the consumer keeps the current
     * period's usage; it grants no fresh budget.
     * @param request Native 3F request to validate and charge against its collateral underlying.
     * @param assets Principal in funding-token base units; zero reverts.
     * @param yieldAssets Yield in funding-token base units.
     */
    function consume(address request, uint256 assets, uint256 yieldAssets) external;
}
