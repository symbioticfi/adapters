// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IMerkleAdapterOracle
 * @notice Interface for flow-adjusted valuation of the adapter and its managed portfolio.
 */
interface IMerkleAdapterOracle {
    /* FUNCTIONS */

    /**
     * @notice Returns current portfolio NAV, reverting when its valuation is missing, stale or frozen.
     * @return assets Latest reported NAV adjusted for completed capital flows since its snapshot.
     */
    function validate() external view returns (uint256 assets);

    /**
     * @notice Returns current portfolio NAV without checking valuation freshness or freeze status.
     * @dev Includes adapter cash, account assets and positions, net of liabilities; excludes vault cash.
     * Reverts if flow reconciliation yields a negative or overflowing value.
     */
    function totalAssets() external view returns (uint256 assets);
}
