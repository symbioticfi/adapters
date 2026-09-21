// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMulticallable} from "@symbioticfi/core/src/interfaces/common/IMulticallable.sol";

/**
 * @title IThreeFPolicy
 * @notice Interface for one executor's funding budget and minimum request yield.
 */
interface IThreeFPolicy is IMulticallable {
    /* ERRORS */

    /// @notice Raised when someone other than the bound executor consumes the budget.
    error InvalidCaller();

    /// @notice Raised when the request yield is below the curator's minimum.
    error TooLowYield();

    /* EVENTS */

    /// @notice Emitted when the owner changes the period budget.
    event SetMaxAssetsPerDuration(uint256 maxAssets, uint256 duration);
    /// @notice Emitted when the owner changes the minimum yield per unit of principal, scaled by 1e6.
    event SetMinYieldPerRequest(uint256 minimum);
    /// @notice Emitted when the executor charges principal to its current period.
    event Consume(uint256 assets);

    /* FUNCTIONS */

    /// @notice Returns the sole executor allowed to consume this budget.
    function executor() external view returns (address);
    /// @notice Returns the minimum yield/principal ratio, scaled by 1e6; this is not annualized.
    function minYieldPerRequest() external view returns (uint256);
    /// @notice Returns the maximum assets, duration in seconds, period start and spent principal.
    function assetLimit() external view returns (uint256, uint256, uint256, uint256);
    /// @notice Returns the unused principal budget in the current period.
    function remainingAssets() external view returns (uint256);
    /// @notice Updates the budget without resetting current usage; owner-only, zero max disables funding.
    function setMaxAssetsPerDuration(uint256 newMaxAssets, uint256 newDuration) external;
    /// @notice Updates the minimum yield immediately; owner-only and independent of the account root.
    function setMinYieldPerRequest(uint256 newMinimum) external;
    /**
     * @notice Checks the yield and charges principal before minting; only the bound executor may call.
     * @dev The executor must validate the request and enforce these exact amounts. A failed mint
     * must revert the entire transaction. Funding is cumulative: claims do not refund the budget.
     * Policies are independent; creating multiple executors does not create a shared asset limit.
     */
    function consume(uint256 assets, uint256 yieldAssets) external;
}
