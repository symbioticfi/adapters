// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IMerkleAdapterOracle
 * @notice Interface for MerkleAdapterOracle.
 */
interface IMerkleAdapterOracle {
    /* FUNCTIONS */

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
