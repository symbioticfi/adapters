// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMulticallable} from "@symbioticfi/core/src/interfaces/common/IMulticallable.sol";

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
 * @notice Interface for per-asset funding budgets and minimum request yield charged by one permanently bound account.
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
     * @notice Raised when someone other than the bound account configures or consumes the budget.
     */
    error InvalidCaller();

    /**
     * @notice Raised when a request is not registered by the trusted request factory.
     */
    error InvalidRequest();

    /**
     * @notice Raised when the request name has no intent id after its eight-byte prefix.
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
     * @notice Emitted when the account changes a collateral asset's budget in funding-token base units.
     */
    event SetMaxAssetsPerDuration(address indexed asset, uint256 maxAssets, uint48 duration);

    /**
     * @notice Emitted when the account changes an asset's minimum yield per unit of principal, scaled by 1e8.
     */
    event SetMinYieldPerRequest(address indexed asset, uint256 minimum);
    /**
     * @notice Emitted when the account charges principal to an asset's current period.
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
     * @notice Sets a collateral asset's budget; only the bound account may call and duration must be nonzero.
     * @dev Authorize configuration through account Merkle leaves that pin the asset, budget and duration.
     * Reconfiguration preserves usage in an active period. Changing duration starts a new period
     * at the current timestamp and carries that usage forward until the new duration expires.
     * A shorter duration can refresh the budget before the old period ends. Zero maxAssets disables spending
     * without erasing usage. Unused capacity never carries into another period.
     * @param asset Collateral underlying whose budget is configured.
     * @param newMaxAssets Funding-token base units allowed in each period; zero disables spending.
     * @param newDuration Period length in seconds.
     */
    function setMaxAssetsPerDuration(address asset, uint256 newMaxAssets, uint48 newDuration) external;

    /**
     * @notice Returns the sole account allowed to configure and consume this policy's budgets.
     * @dev Set once by initialize through the factory from abi.encode(account); there is no setter.
     * Budgets, minimums and current-period usage survive migration.
     */
    function account() external view returns (address);
    /**
     * @notice Returns an asset's minimum yield/principal ratio, scaled by 1e8; this is not annualized.
     * @dev Unset or zero disables the yield floor, allowing zero-yield requests if the budget is enabled.
     */
    function minYieldPerRequest(address asset) external view returns (uint256);
    /**
     * @notice Updates an asset's minimum yield immediately; only the bound account may call.
     * @param asset Collateral underlying whose minimum is configured.
     * @dev Authorize configuration through account Merkle leaves that pin the asset and minimum.
     * Zero deliberately disables the yield floor. Set the intended minimum before enabling the budget.
     * @param newMinimum Yield/principal ratio scaled by 1e8 (1e8 = 100%, 2_000_000 = 2%); not annualized.
     */
    function setMinYieldPerRequest(address asset, uint256 newMinimum) external;
    /**
     * @notice Validates a request, checks its yield and charges its collateral budget; only the bound account may call.
     * @dev Requires factory membership and a decimal intent id after the name's first eight bytes. The prefix
     * contents are not validated. The facility must bind that id to the same request and identify its target
     * as a position manager. Resolves the manager's collateral through underlying(); zero underlying is
     * rejected. Invalid decimal digits and oversized ids revert through Strings.parseUint, and failed
     * dependency reads bubble their revert data.
     * The caller cannot select another asset's budget. Requests sharing a collateral budget must use the
     * same funding token and denomination; use separate policy instances otherwise.
     * The caller must enforce these exact amounts. Within a guarded sequence the accompanying
     * checks bind `assets` and `yieldAssets` to the observed principal and yield deltas, so an
     * understated charge reverts. A failed mint must revert the entire transaction. Funding is
     * cumulative: claims do not refund the budget. Authorize only the complete account-side
     * RecipeCapability consume-and-mint leaf; a separate raw mint leaf can bypass the policy.
     * @param request Native 3F request to validate and charge against its collateral underlying.
     * @param assets Principal in funding-token base units; zero reverts.
     * @param yieldAssets Yield in funding-token base units.
     */
    function consume(address request, uint256 assets, uint256 yieldAssets) external;
}
