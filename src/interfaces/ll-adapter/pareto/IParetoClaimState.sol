// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IParetoClaimState
 * @notice Native receipt settlement facts used by direct withdrawal claims.
 */
interface IParetoClaimState {
    /* FUNCTIONS */

    /// @notice Returns the receipt strategy bound to the CDO.
    function strategy() external view returns (address);

    /// @notice Returns whether the CDO permits instant withdrawal claims.
    function allowInstantWithdraw() external view returns (bool);

    /// @notice Returns zero in pool-close mode, which waives the normal epoch wait.
    function epochEndDate() external view returns (uint256);

    /// @notice Returns the last normal withdrawal request epoch for the owner.
    function lastWithdrawRequest(address account) external view returns (uint256);

    /// @notice Returns the owner's normal fixed withdrawal entitlement.
    function withdrawsRequests(address account) external view returns (uint256);

    /// @notice Returns the owner's instant fixed withdrawal entitlement.
    function instantWithdrawsRequests(address account) external view returns (uint256);

    /// @notice Returns open principal, its epoch, settled principal and settled interest.
    function apr0Users(address account) external view returns (uint256, uint256, uint256, uint256);

    /// @notice Returns the finalized net APR0 rate, scaled by 1e18.
    function apr0RateByEpoch(uint256 epoch) external view returns (uint256);
}
