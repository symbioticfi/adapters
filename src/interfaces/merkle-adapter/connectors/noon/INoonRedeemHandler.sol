// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title INoonRedeemHandler
/// @notice Noon USN conversion into an approved collateral asset.
interface INoonRedeemHandler {
    /// @notice Quotes the collateral paid for the specified USN amount.
    /// @param collateral The collateral token.
    /// @param usnAmount The USN amount in token units.
    /// @return assets The collateral amount in token units.
    function calculateCollateralAmount(address collateral, uint256 usnAmount) external view returns (uint256 assets);
}
