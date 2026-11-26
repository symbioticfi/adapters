// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.4;

/**
 * @title IBaseAliasThreeFPolicy
 * @notice Ethereum dispatch policy for funding Base 3F requests with USDC from a MerkleAccount's alias.
 * @dev The bound MerkleAccount configures the policy and charges it before submitting the Base portal deposits.
 */
interface IBaseAliasThreeFPolicy {
    /* ERRORS */

    /// @notice Raised when a mint has zero principal.
    error InvalidAssets();

    /// @notice Raised when the account is zero or the caller is not the bound MerkleAccount.
    error InvalidCaller();

    /// @notice Raised when a request is zero or has no approved Base collateral underlying.
    error InvalidRequest();

    /// @notice Raised when the mint's lower yield bound is below the configured minimum ratio.
    error TooLowYield();

    /* EVENTS */

    /// @notice Emitted when an Ethereum dispatch charges the budget for a Base request.
    event Consume(address indexed request, address indexed underlyingAsset, uint256 maxPrincipal, uint256 minYield);

    /// @notice Emitted when the dispatch budget for a Base collateral underlying changes.
    event SetMaxAssetsPerDuration(address indexed underlyingAsset, uint256 maxAssets, uint48 duration);

    /// @notice Emitted when the minimum yield ratio for a Base collateral underlying changes.
    event SetMinYieldPerRequest(address indexed underlyingAsset, uint256 minimum);

    /// @notice Emitted when a Base request is registered or revoked.
    event SetRequestUnderlying(address indexed request, address indexed underlyingAsset);

    /* FUNCTIONS */

    /// @notice Returns the Ethereum MerkleAccount.
    function account() external view returns (address);

    /// @notice Returns the registered Base collateral underlying, or zero for an unregistered request.
    function requestUnderlying(address request) external view returns (address);

    /// @notice Returns the minimum yield ratio (yield divided by principal, scaled by 1e8).
    function minYieldPerRequest(address underlyingAsset) external view returns (uint256);

    /// @notice Returns the remaining Base USDC dispatch budget in base units.
    function remainingAssets(address underlyingAsset) external view returns (uint256);

    /// @notice Registers a verified Base request and its collateral underlying. Pass zero as the underlying to revoke it.
    function setRequestUnderlying(address request, address underlyingAsset) external;

    /// @notice Sets the maximum Base USDC that may be dispatched for this underlying over one period.
    function setMaxAssetsPerDuration(address underlyingAsset, uint256 maxAssets, uint48 duration) external;

    /// @notice Sets the minimum allowed yield ratio for this underlying, scaled by 1e8.
    function setMinYieldPerRequest(address underlyingAsset, uint256 minimum) external;

    /// @notice Charges the mint's maximum principal in Base USDC and checks its minimum yield bound.
    /// @dev The charge persists after Ethereum dispatch even if the Base mint fails or pulls less USDC.
    function consume(address request, uint256 maxPrincipal, uint256 minYield) external;
}
