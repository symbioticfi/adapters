// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAssetRateLimits} from "./IAssetRateLimits.sol";
import {ICapability} from "./ICapability.sol";

/**
 * @dev Maximum number of active 3F requests tracked by one adapter.
 */
uint256 constant MAX_REQUESTS = 50;

/**
 * @dev Prefix before the request intent id.
 */
bytes constant REQUEST_NAME_PREFIX = "request-";

/**
 * @dev Length of the request name prefix.
 */
uint256 constant REQUEST_NAME_PREFIX_LENGTH = 8;

/**
 * @title IThreeFCapability
 * @notice Interface for adapter-context 3F push minting with collateral-specific funding budgets and minimum yields.
 */
interface IThreeFCapability is ICapability, IAssetRateLimits {
    /* ERRORS */

    /**
     * @notice Raised when the request already has an active position.
     */
    error AlreadyRequest();

    /**
     * @notice Raised when authorization is empty, has zero yield, or does not fund exactly its principal.
     */
    error InvalidMintAuthorization();

    /**
     * @notice Raised when the request name has no valid numeric id after its request- prefix.
     */
    error InvalidRequestName();

    /**
     * @notice Raised when the adapter's mint execution deadline has passed.
     */
    error MintDeadlineExpired();

    /**
     * @notice Raised when the request is not whitelisted, or an untracked request is finalized.
     */
    error NotRequest();

    /**
     * @notice Raised when the trusted facility binds the parsed intent to another request.
     */
    error RequestMismatch();

    /**
     * @notice Raised when the live authorization exceeds the caller's principal or yield bounds.
     */
    error SlippageExceeded();

    /**
     * @notice Raised when the request yield is below the configured minimum.
     */
    error TooLowYield();

    /**
     * @notice Raised when the maximum number of active requests is reached.
     */
    error TooManyRequests();

    /**
     * @notice Raised when the intent target is not a position manager.
     */
    error UnsupportedTarget();

    /**
     * @notice Raised when the request funding asset differs from the adapter vault asset.
     */
    error WrongAsset();

    /* EVENTS */

    /**
     * @notice Emitted when the minimum request yield for a collateral underlying changes.
     */
    event SetMinYieldPerRequest(address indexed asset, uint256 minYieldPerRequest);

    /**
     * @notice Emitted when authorized principal is funded and the adapter receives PT/YT.
     * @param request Request receiving the principal.
     * @param asset Collateral underlying used to validate limits.
     * @param principalAssets Principal funded in vault-asset units.
     * @param yieldAssets Yield minted in vault-asset units.
     */
    event MintRequest(address indexed request, address indexed asset, uint256 principalAssets, uint256 yieldAssets);

    /**
     * @notice Emitted when a request is finalized and recovered assets are returned to the adapter.
     * @param request Request address.
     */
    event FinalizeRequest(address indexed request);

    /* FUNCTIONS */

    /**
     * @notice Returns the request whitelist.
     * @return requestWhitelist Request whitelist address.
     */
    function REQUEST_WHITELIST() external view returns (address requestWhitelist);

    /**
     * @notice Returns the trusted facility used to resolve request intents and collateral.
     * @return facility Facility address.
     */
    function FACILITY() external view returns (address facility);

    /**
     * @notice Returns the minimum request yield in ppm for a collateral underlying.
     * @param asset Collateral underlying, not the request funding asset.
     */
    function minYieldPerRequest(address asset) external view returns (uint256 minimum);

    /**
     * @notice Returns an active request by index.
     * @param index Request index.
     * @return request Request address.
     */
    function requests(uint256 index) external view returns (address request);

    /**
     * @notice Returns the one-based active request index, or zero if inactive.
     * @param request Request address.
     * @return index One-based active request index.
     */
    function requestIndex(address request) external view returns (uint256 index);

    /**
     * @notice Returns the principal stored when the request was funded.
     * @param request Request address.
     * @return assets Principal in vault-asset units.
     */
    function pendingAssets(address request) external view returns (uint256 assets);

    /**
     * @notice Returns the number of active requests currently tracked.
     * @return length Active request count.
     */
    function requestsLength() external view returns (uint256 length);

    /**
     * @notice Returns vault assets represented by active 3F requests, excluding the adapter's idle balance.
     * @return assets Assets represented by tracked requests.
     */
    function threeFPositionAssets() external view returns (uint256 assets);

    /**
     * @notice Sets the minimum request yield through a curator-authorized adapter call.
     * @param asset Collateral underlying resolved through the trusted facility and position manager.
     * @param newMinimum Minimum request yield in parts per million of principal.
     */
    function setMinYieldPerRequest(address asset, uint256 newMinimum) external;

    /**
     * @notice Funds and mints a live push authorization for the adapter through an authorized self-call.
     * @dev Requires an adapter self-call. The adapter must approve the request separately before minting.
     * Positions and funding tokens belong to the adapter. This capability does not change token allowances.
     * @param request Whitelisted request bound to an intent in the trusted facility.
     * @param maxPrincipalAssets Maximum acceptable authorized principal in vault-asset units.
     * @param minYieldAssets Minimum acceptable authorized yield in vault-asset units.
     * @param deadline Last timestamp at which this execution is valid.
     */
    function mintRequest(address request, uint128 maxPrincipalAssets, uint128 minYieldAssets, uint256 deadline) external;

    /**
     * @notice Finalizes a tracked request, receiving principal and yield directly on the adapter.
     * @dev Requires an adapter self-call, including when the request is already redeemable.
     * @param request Active request address.
     */
    function finalizeRequest(address request) external;
}
