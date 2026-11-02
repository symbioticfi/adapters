// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IMerkleAdapterOracle
 * @notice Interface for accepted valuation data used by the adapter to calculate current NAV.
 */
interface IMerkleAdapterOracle {
    /* ERRORS */

    /**
     * @notice Raised when an oracle implementation requires an accepted snapshot.
     */
    error OracleStale();

    /* FUNCTIONS */

    /**
     * @notice Returns the reported NAV eligible for vault valuation, or zero before the first report.
     * @dev A report accepted in the current block becomes eligible in the next block.
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Returns the latest snapshot block eligible to release staged cash, or zero if none is eligible.
     * @dev During an acceptance block, returns the latest snapshot accepted before that block.
     */
    function snapshotBlock() external view returns (uint48);

    /**
     * @notice Returns the snapshot block and portfolio NAV eligible for vault valuation, or (0, 0) before the first report.
     * @dev Returns snapshotBlock() and totalAssets(); both expose the previous report during the acceptance block.
     * @return reportBlock Completed block whose portfolio was valued.
     * @return assets Portfolio NAV at that block, before subsequent capital flows.
     */
    function latestSnapshot() external view returns (uint48 reportBlock, uint256 assets);
}
