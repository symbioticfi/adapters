// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IMerkleAdapterOracle
 * @notice Interface for accepted valuation data used by the adapter to calculate current NAV.
 */
interface IMerkleAdapterOracle {
    /* ERRORS */

    /**
     * @notice Raised when no snapshot has been accepted or the last accepted NAV has expired.
     */
    error OracleStale();

    /* FUNCTIONS */

    /**
     * @notice Returns the last accepted reported NAV, or zero before the first report.
     * @dev Does not validate freshness. Use latestSnapshot() for accounting.
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Returns the block number of the most recently accepted snapshot, or zero before the first report.
     */
    function snapshotBlock() external view returns (uint48);

    /**
     * @notice Returns the timestamp of the most recently accepted snapshot, or zero before the first report.
     */
    function snapshotTimestamp() external view returns (uint48);

    /**
     * @notice Returns the immutable maximum snapshot age in seconds.
     * @dev Applies to report delivery, curator review and latestSnapshot(). The exact age limit is valid.
     */
    function MAX_REPORT_AGE() external view returns (uint48);

    /**
     * @notice Returns the latest accepted snapshot block and its reported portfolio NAV.
     * @dev Reverts with OracleStale when no snapshot has been accepted or it has expired.
     * Does not read adapter flows. The adapter adjusts this NAV for capital flows since the snapshot.
     * @return reportBlock Completed block whose portfolio was valued.
     * @return assets Portfolio NAV at that block, before subsequent capital flows.
     */
    function latestSnapshot() external view returns (uint48 reportBlock, uint256 assets);
}
