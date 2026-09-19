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
     * @dev Adapter calls this before NAV-dependent operations. Raw accounting getters remain
     * available for recovery and offchain inspection while validation fails.
     */
    function validate() external view;

    /**
     * @notice Returns the current accounting epoch.
     */
    function nonce() external view returns (uint256);

    /**
     * @notice Returns workflow NAV excluding pending allocations and matured deallocation reserves.
     * @return assets NAV in vault-asset units; the adapter adds its excluded reserves back.
     */
    function totalAssets() external view returns (uint256 assets);
}
