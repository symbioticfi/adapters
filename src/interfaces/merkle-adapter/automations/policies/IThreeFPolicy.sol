// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAssetRateLimits} from "../../IAssetRateLimits.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMulticallable} from "@symbioticfi/core/src/interfaces/common/IMulticallable.sol";

/**
 * @title IThreeFPolicy
 * @notice Interface for per-asset funding budgets and minimum request yield charged by one consumer.
 */
interface IThreeFPolicy is IMigratableEntity, IMulticallable, IAssetRateLimits {
    /* ERRORS */

    /// @notice Raised when the charged principal is zero.
    error InvalidAssets();

    /// @notice Raised when someone other than the current consumer consumes the budget.
    error InvalidCaller();

    /// @notice Raised when a migration carries payload this implementation does not expect.
    error InvalidMigrationData();

    /// @notice Raised when the request yield is below the curator's minimum.
    error TooLowYield();

    /* EVENTS */

    /// @notice Emitted when the owner moves the budget to another consumer.
    event SetConsumer(address indexed consumer);
    /// @notice Emitted when the owner changes an asset's minimum yield per unit of principal, scaled by 1e6.
    event SetMinYieldPerRequest(address indexed asset, uint256 minimum);
    /// @notice Emitted when the consumer charges principal to an asset's current period.
    event Consume(address indexed asset, uint256 assets);

    /* FUNCTIONS */

    /**
     * @notice Returns the sole address allowed to consume this policy's budgets.
     * @dev Set by `initialize` through the factory, from `abi.encode(consumer)`; zero leaves the
     * policy inert until the owner points it somewhere. Budgets and minimums are configured
     * afterwards and survive migration along with the current period's usage.
     */
    function consumer() external view returns (address);
    /// @notice Returns an asset's minimum yield/principal ratio, scaled by 1e6; this is not annualized.
    function minYieldPerRequest(address asset) external view returns (uint256);
    /**
     * @notice Moves the budget to another consumer; owner-only, zero disables all consumption.
     * @dev For the guarded mint leaf and ThreeFExecuting, use the account as the consumer: an executor
     * drives the leaf through `account.manage`, so the charge originates from the account. Direct
     * managers using that leaf share its budget. Repointing preserves usage and immediately blocks
     * the previous consumer. Never authorize a bare `consume` Merkle leaf: inside a guarded sequence
     * a charge requires the accompanying mint, on its own it burns budget.
     */
    function setConsumer(address newConsumer) external;
    /// @notice Updates an asset's minimum yield immediately; owner-only and independent of the account root.
    function setMinYieldPerRequest(address asset, uint256 newMinimum) external;
    /**
     * @notice Checks the yield and charges principal before minting; only the consumer may call.
     * @dev The caller must enforce these exact amounts. Within a guarded sequence the accompanying
     * checks bind `assets` and `yieldAssets` to the observed principal and yield deltas, so an
     * understated charge reverts. A failed mint must revert the entire transaction. Funding is
     * cumulative: claims do not refund the budget. Repointing the consumer keeps the current
     * period's usage; it grants no fresh budget.
     * @param asset Collateral underlying whose period budget is charged.
     * @param assets Principal in funding-token base units; zero reverts.
     * @param yieldAssets Yield in funding-token base units.
     */
    function consume(address asset, uint256 assets, uint256 yieldAssets) external;
}
