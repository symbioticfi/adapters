// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/// @dev Maximum number of active 3F requests tracked by one capability.
uint256 constant MAX_REQUESTS = 50;

/// @dev Prefix before the request intent id.
bytes constant REQUEST_NAME_PREFIX = "request-";

/// @dev Length of the request name prefix.
uint256 constant REQUEST_NAME_PREFIX_LENGTH = 8;

/// @title IThreeFCapability
/// @notice Adapter-controlled 3F push minting with collateral-specific request limits.
interface IThreeFCapability is IMigratableEntity {
    /// @notice Reverts when the request already has an active position.
    error AlreadyRequest();

    /// @notice Reverts when a function is not called by the bound adapter.
    error InvalidCaller();

    /// @notice Reverts when migration data is not supported by this implementation.
    error InvalidMigrationData();

    /// @notice Reverts when authorization is empty, has zero yield, or does not fund exactly its principal.
    error InvalidMintAuthorization();

    /// @notice Reverts when the request name has no valid numeric id after its request- prefix.
    error InvalidRequestName();

    /// @notice Reverts when the adapter's mint execution deadline has passed.
    error MintDeadlineExpired();

    /// @notice Reverts when the request is not whitelisted, or an untracked request is finalized.
    error NotRequest();

    /// @notice Reverts when the trusted facility binds the parsed intent to another request.
    error RequestMismatch();

    /// @notice Reverts when the live authorization exceeds the caller's principal or yield bounds.
    error SlippageExceeded();

    /// @notice Reverts when the request principal exceeds the configured maximum.
    error TooLargeRequest();

    /// @notice Reverts when the request yield is below the configured minimum.
    error TooLowYield();

    /// @notice Reverts when the maximum number of active requests is reached.
    error TooManyRequests();

    /// @notice Reverts when the request principal is below the configured minimum.
    error TooSmallRequest();

    /// @notice Reverts when the collateral underlying has no configured maximum.
    error UnconfiguredAsset();

    /// @notice Reverts when the intent target is not a position manager.
    error UnsupportedTarget();

    /// @notice Reverts when the request funding asset differs from the adapter vault asset.
    error WrongAsset();

    /// @notice Principal and yield bounds keyed by the intent's collateral underlying.
    /// @param minYieldPerRequest Minimum yield as parts per million of principal.
    /// @param minAssetsPerRequest Minimum principal in vault-asset units.
    /// @param maxAssetsPerRequest Maximum principal in vault-asset units; zero disables the asset.
    struct Limits {
        uint256 minYieldPerRequest;
        uint256 minAssetsPerRequest;
        uint256 maxAssetsPerRequest;
    }

    /// @notice Emitted when collateral-specific limits are set.
    /// @param asset Collateral underlying used as the limits key.
    /// @param minYieldPerRequest Minimum yield in ppm.
    /// @param minAssetsPerRequest Minimum principal in vault-asset units.
    /// @param maxAssetsPerRequest Maximum principal in vault-asset units.
    event SetLimitsPerRequest(
        address indexed asset, uint256 minYieldPerRequest, uint256 minAssetsPerRequest, uint256 maxAssetsPerRequest
    );

    /// @notice Emitted after authorized principal is funded and the capability receives PT/YT.
    /// @param request Request receiving the principal.
    /// @param asset Collateral underlying used to validate limits.
    /// @param principalAssets Principal funded in vault-asset units.
    /// @param yieldAssets Yield minted in vault-asset units.
    event MintRequest(address indexed request, address indexed asset, uint256 principalAssets, uint256 yieldAssets);

    /// @notice Emitted when a request is finalized and recovered assets are returned to the adapter.
    /// @param request Request address.
    event FinalizeRequest(address indexed request);

    /// @notice Returns the only adapter authorized to configure and fund this capability.
    /// @return adapter_ Bound adapter address.
    function adapter() external view returns (address adapter_);

    /// @notice Returns the request whitelist.
    /// @return requestWhitelist Request whitelist address.
    function REQUEST_WHITELIST() external view returns (address requestWhitelist);

    /// @notice Returns the trusted facility used to resolve request intents and collateral.
    /// @return facility Facility address.
    function FACILITY() external view returns (address facility);

    /// @notice Returns the configured limits for a collateral underlying.
    /// @param asset Collateral underlying, not the request funding asset.
    /// @return minYieldPerRequest Minimum yield in ppm.
    /// @return minAssetsPerRequest Minimum principal in vault-asset units.
    /// @return maxAssetsPerRequest Maximum principal in vault-asset units; zero disables the asset.
    function limits(address asset)
        external
        view
        returns (uint256 minYieldPerRequest, uint256 minAssetsPerRequest, uint256 maxAssetsPerRequest);

    /// @notice Returns an active request by index.
    /// @param index Request index.
    /// @return request Request address.
    function requests(uint256 index) external view returns (address request);

    /// @notice Returns the one-based active request index, or zero if inactive.
    /// @param request Request address.
    /// @return index One-based active request index.
    function requestIndex(address request) external view returns (uint256 index);

    /// @notice Returns the principal stored when the request was funded.
    /// @param request Request address.
    /// @return assets Principal in vault-asset units.
    function pendingAssets(address request) external view returns (uint256 assets);

    /// @notice Returns the number of active requests currently tracked.
    /// @return length Active request count.
    function requestsLength() external view returns (uint256 length);

    /// @notice Returns vault assets held directly or represented by active requests.
    /// @return assets Total managed assets.
    function totalAssets() external view returns (uint256 assets);

    /// @notice Sets principal and yield limits for a collateral underlying.
    /// @param asset Collateral underlying resolved through the trusted facility and position manager.
    /// @param newMinYieldPerRequest Minimum request yield in ppm.
    /// @param newMinAssetsPerRequest Minimum principal in vault-asset units.
    /// @param newMaxAssetsPerRequest Maximum principal in vault-asset units; zero disables the asset.
    function setLimitsPerRequest(
        address asset,
        uint256 newMinYieldPerRequest,
        uint256 newMinAssetsPerRequest,
        uint256 newMaxAssetsPerRequest
    ) external;

    /// @notice Funds and mints a live push authorization for this capability through the bound adapter.
    /// @dev Intended to follow liquidity preparation in the same MerkleAdapter.manage batch.
    /// @param request Whitelisted request bound to an intent in the trusted facility.
    /// @param maxPrincipalAssets Maximum acceptable authorized principal in vault-asset units.
    /// @param minYieldAssets Minimum acceptable authorized yield in vault-asset units.
    /// @param deadline Last timestamp at which this execution is valid.
    function mintRequest(address request, uint128 maxPrincipalAssets, uint128 minYieldAssets, uint256 deadline) external;

    /// @notice Finalizes a request and transfers its recovered principal and yield to the adapter.
    /// @param request Active request address.
    function finalizeRequest(address request) external;
}
