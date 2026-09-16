// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
     * @notice Returns the adapter's total managed assets.
     * @return assets Total assets reported for the adapter.
     */
    function totalAssets() external view returns (uint256 assets);
}
