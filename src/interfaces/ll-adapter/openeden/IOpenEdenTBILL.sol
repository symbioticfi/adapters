// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IOpenEdenTBILL
/// @notice OpenEden TBILL native share-to-underlying conversion.
interface IOpenEdenTBILL {
    /// @notice Returns the TBILL underlying asset.
    /// @return asset The underlying token.
    function underlying() external view returns (address asset);

    /// @notice Returns the underlying NAV of TBILL shares before the redemption transaction fee.
    /// @param shares The TBILL amount in token units.
    /// @return assets The underlying amount in token units.
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
}
