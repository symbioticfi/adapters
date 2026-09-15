// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IThreeFRequestCallback} from "../3f-adapter/IThreeFRequestCallback.sol";
import {Offer} from "../3f-adapter/ThreeFTypes.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/// @dev Maximum number of active 3F requests tracked by one capability.
uint256 constant MAX_REQUESTS = 50;

/// @title IThreeFCapability
/// @notice Interface for an adapter-bound 3F bridge facilitator capability.
interface IThreeFCapability is IMigratableEntity, IThreeFRequestCallback, IERC1271 {
    /// @notice Reverts when the request already has an active position.
    error AlreadyRequest();

    /// @notice Reverts when the consumed 3F offer is expired.
    error ExpiredOffer();

    /// @notice Reverts when a function is not called by the bound adapter.
    error InvalidCaller();

    /// @notice Reverts when the consumed 3F offer fields do not match the callback.
    error InvalidOffer();

    /// @notice Reverts when migration data is not supported by this implementation.
    error InvalidMigrationData();

    /// @notice Reverts when the callback caller is not a whitelisted 3F request.
    error NotRequest();

    /// @notice Reverts when the request principal exceeds the configured per-request maximum.
    error TooLargeRequest();

    /// @notice Reverts when the request yield is below the configured minimum.
    error TooLowYield();

    /// @notice Reverts when the capability already tracks the maximum number of active requests.
    error TooManyRequests();

    /// @notice Reverts when the request principal is below the configured per-request minimum.
    error TooSmallRequest();

    /// @notice Reverts when a 3F request asset differs from the adapter vault asset.
    error WrongAsset();

    /// @notice Emitted when the offer signer is set.
    /// @param offerSigner Offer signer.
    event SetOfferSigner(address indexed offerSigner);

    /// @notice Emitted when per-request limits are set.
    /// @param minYieldPerRequest Minimum request yield in ppm.
    /// @param minAssetsPerRequest Minimum principal assets per request.
    /// @param maxAssetsPerRequest Maximum principal assets per request.
    event SetLimitsPerRequest(uint256 minYieldPerRequest, uint256 minAssetsPerRequest, uint256 maxAssetsPerRequest);

    /// @notice Emitted when a 3F request nonce is set for capability-made offers.
    /// @param request Request address.
    /// @param nonce New nonce value.
    event SetRequestNonce(address indexed request, uint256 nonce);

    /// @notice Emitted when a 3F request is consumed by this capability.
    /// @param request Request address.
    /// @param offer Consumed 3F offer payload.
    /// @param principalAssets Principal assets funded into the request.
    /// @param yieldAssets Yield assets minted by the request.
    event OnRequestConsumed(address indexed request, Offer offer, uint256 principalAssets, uint256 yieldAssets);

    /// @notice Emitted when a request is finalized and recovered assets are returned to the adapter.
    /// @param request Request address.
    event FinalizeRequest(address indexed request);

    /// @notice Returns the only adapter authorized to configure and fund this capability.
    /// @return adapter_ Adapter address.
    function adapter() external view returns (address adapter_);

    /// @notice Returns the request whitelist.
    /// @return requestWhitelist Request whitelist.
    function REQUEST_WHITELIST() external view returns (address requestWhitelist);

    /// @notice Returns the signer accepted by EIP-1271 offer validation.
    /// @return signer Offer signer.
    function offerSigner() external view returns (address signer);

    /// @notice Returns the minimum request yield in ppm.
    /// @return ppm Minimum request yield in ppm.
    function minYieldPerRequest() external view returns (uint256 ppm);

    /// @notice Returns the minimum principal assets accepted per request.
    /// @return assets Minimum principal assets per request.
    function minAssetsPerRequest() external view returns (uint256 assets);

    /// @notice Returns the maximum principal assets accepted per request.
    /// @return assets Maximum principal assets per request.
    function maxAssetsPerRequest() external view returns (uint256 assets);

    /// @notice Returns an active request by index.
    /// @param index Request index.
    /// @return request Request address.
    function requests(uint256 index) external view returns (address request);

    /// @notice Returns the one-based active request index, or zero if inactive.
    /// @param request Request address.
    /// @return index One-based active request index.
    function requestIndex(address request) external view returns (uint256 index);

    /// @notice Returns the principal assets stored when the request was consumed.
    /// @param request Request address.
    /// @return assets Consumed principal assets.
    function pendingAssets(address request) external view returns (uint256 assets);

    /// @notice Returns the number of active requests currently tracked.
    /// @return length Active request count.
    function requestsLength() external view returns (uint256 length);

    /// @notice Returns the vault-asset value held directly or represented by active requests.
    /// @return assets Total managed assets.
    function totalAssets() external view returns (uint256 assets);

    /// @notice Returns whether a signature is valid for the configured offer signer.
    /// @param hash Signed offer digest.
    /// @param signature Offer signature.
    /// @return magicValue ERC-1271 magic value when valid, or `0xffffffff` when invalid.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4 magicValue);

    /// @notice Sets the signer accepted by EIP-1271 offer validation.
    /// @param signer Offer signer.
    function setOfferSigner(address signer) external;

    /// @notice Sets per-request principal and yield limits.
    /// @param newMinYieldPerRequest Minimum request yield in ppm.
    /// @param newMinAssetsPerRequest Minimum principal assets per request.
    /// @param newMaxAssetsPerRequest Maximum principal assets per request.
    function setLimitsPerRequest(
        uint256 newMinYieldPerRequest,
        uint256 newMinAssetsPerRequest,
        uint256 newMaxAssetsPerRequest
    ) external;

    /// @notice Advances this capability's offer nonce in a whitelisted 3F request.
    /// @param request Whitelisted 3F request using the adapter vault asset.
    /// @param newNonce New request-local nonce for this capability as maker.
    function setRequestNonce(address request, uint256 newNonce) external;

    /// @notice Finalizes a request and transfers its recovered assets to the adapter.
    /// @param request Request address.
    function finalizeRequest(address request) external;
}
