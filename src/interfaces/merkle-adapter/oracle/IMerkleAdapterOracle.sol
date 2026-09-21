// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IMerkleAdapterOracle
 * @notice Interface for MerkleAdapterOracle.
 */
interface IMerkleAdapterOracle {
    /* FUNCTIONS */

    /**
     * @notice Checks that a workflow is accepted and its NAV is fresh and unfrozen; reverts otherwise.
     * @dev An accepted report proves workflow acceptance; missing or expired NAV is stale.
     * Adapter calls this before NAV-dependent operations. Raw accounting getters remain
     * available for recovery and offchain inspection while validation fails.
     * @return assets Accepted NAV excluding pending allocations and matured withdrawals.
     * @return batchCutoff Timestamp closing the current allocation and withdrawal batch.
     */
    function validate() external view returns (uint256 assets, uint256 batchCutoff);

    /**
     * @notice Returns the current accounting epoch.
     */
    function nonce() external view returns (uint256);

    /**
     * @notice Returns the timestamp closing the batch consumed by the next accepted report.
     * @dev Before this timestamp, allocations and requests modify the current nonce's batch;
     * at or after it, they modify the next batch. Zero permits the initial bootstrap report.
     * Only an accepted report advances the cutoff, always to a future scheduled cutoff.
     */
    function cutoff() external view returns (uint256);

    /**
     * @notice Returns workflow NAV excluding pending allocations and matured deallocation reserves.
     * @return assets NAV in vault-asset units; the adapter adds its excluded reserves back.
     */
    function totalAssets() external view returns (uint256 assets);
}
