// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {Adapter} from "./Adapter.sol";

import {IAdapter} from "../interfaces/IAdapter.sol";
import {IThreeFAdapter, MAX_REQUESTS} from "../interfaces/IThreeFAdapter.sol";
import {IThreeFRequestCallback} from "../interfaces/3f-adapter/IThreeFRequestCallback.sol";
import {IThreeFRequest} from "../interfaces/3f-adapter/IThreeFRequest.sol";
import {IThreeFWhitelist} from "../interfaces/3f-adapter/IThreeFWhitelist.sol";
import {Offer, YIELD_PRECISION} from "../interfaces/3f-adapter/ThreeFTypes.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IUniversalDelegator} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";
import {IVaultV2} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";

/// @title ThreeFAdapter
/// @notice VaultV2 adapter contract for 3F bridge facilitator requests.
contract ThreeFAdapter is Adapter, IThreeFAdapter {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IThreeFAdapter
    address public immutable REQUEST_WHITELIST;

    /* STATE VARIABLES */

    /// @inheritdoc IThreeFAdapter
    address public offerSigner;

    /// @inheritdoc IThreeFAdapter
    uint256 public minYieldPerRequest;

    /// @inheritdoc IThreeFAdapter
    uint256 public minAssetsPerRequest;

    /// @inheritdoc IThreeFAdapter
    uint256 public maxAssetsPerRequest;

    /// @inheritdoc IThreeFAdapter
    address[] public requests;

    /// @inheritdoc IThreeFAdapter
    mapping(address request => uint256 index) public requestIndex;

    /// @inheritdoc IThreeFAdapter
    mapping(address request => uint256 assets) public pendingAssets;

    /// @dev Opens allocatable capacity only during the just-in-time request callback.
    bool internal transient _inConsume;

    /* CONSTRUCTOR */

    constructor(address newVaultFactory, address newAdapterFactory, address newRequestWhitelist)
        Adapter(newVaultFactory, newAdapterFactory)
    {
        REQUEST_WHITELIST = newRequestWhitelist;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IThreeFAdapter
    function isValidSignature(bytes32 hash, bytes calldata signature) public view returns (bytes4) {
        return SignatureChecker.isValidSignatureNowCalldata(offerSigner, hash, signature)
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }

    /// @inheritdoc IAdapter
    function allocatable() public view override(Adapter, IAdapter) returns (uint256) {
        return _inConsume ? super.allocatable() : 0;
    }

    /// @inheritdoc IAdapter
    function totalAssets() public view override(Adapter, IAdapter) returns (uint256 assets) {
        assets = freeAssets();
        uint256 length = requests.length;
        for (uint256 i; i < length; ++i) {
            address request = requests[i];
            if (IThreeFRequest(request).canWithdraw()) {
                (uint256 ptShares, uint256 ytShares) = IThreeFRequest(request).balancesOf(address(this));
                (uint256 pAssets, uint256 yAssets) = IThreeFRequest(request).convertToAssets(ptShares, ytShares);
                assets += pAssets + yAssets;
            } else {
                assets += pendingAssets[request];
            }
        }
    }

    /// @inheritdoc IThreeFAdapter
    function requestsLength() public view returns (uint256) {
        return requests.length;
    }

    /// @inheritdoc IThreeFAdapter
    function getMaxAssets() public returns (uint256 assets) {
        address delegator = IVaultV2(vault).delegator();
        if (IUniversalDelegator(delegator).sweepPending() > 0) {
            return 0;
        }
        return Math.min(
            IUniversalDelegator(delegator).limitOf(address(this)).saturatingSub(totalAssets()),
            IVaultV2(vault).withdrawable()
        );
    }

    /// @inheritdoc IThreeFAdapter
    function setOfferSigner(address newOfferSigner) public onlyOwner {
        offerSigner = newOfferSigner;

        emit SetOfferSigner(newOfferSigner);
    }

    /// @inheritdoc IThreeFAdapter
    function setLimitsPerRequest(
        uint256 newMinYieldPerRequest,
        uint256 newMinAssetsPerRequest,
        uint256 newMaxAssetsPerRequest
    ) public onlyOwner {
        minYieldPerRequest = newMinYieldPerRequest;
        minAssetsPerRequest = newMinAssetsPerRequest;
        maxAssetsPerRequest = newMaxAssetsPerRequest;

        emit SetLimitsPerRequest(newMinYieldPerRequest, newMinAssetsPerRequest, newMaxAssetsPerRequest);
    }

    /// @inheritdoc IThreeFAdapter
    function setRequestNonce(address request, uint256 newNonce) public onlyOwner {
        _validateRequest(request);

        IThreeFRequest(request).setNonce(newNonce);

        emit SetRequestNonce(request, newNonce);
    }

    /* PUBLIC FUNCTIONS (3F) */

    /// @inheritdoc IThreeFRequestCallback
    function onRequestConsumed(Offer calldata offer, bytes calldata, uint256 principalAssets, uint256 yieldAssets)
        public
        nonReentrant
    {
        _validateRequest(msg.sender);

        if (offer.maker != address(this) || !offer.useCallback || offer.expectedReturn == 0) revert InvalidOffer();

        if (offer.expiration < block.timestamp) revert ExpiredOffer();

        if (requests.length >= MAX_REQUESTS) revert TooManyRequests();

        if (requestIndex[msg.sender] > 0) revert AlreadyRequest();

        if (principalAssets < minAssetsPerRequest) revert TooSmallRequest();

        if (principalAssets > maxAssetsPerRequest) revert TooLargeRequest();

        // forgefmt: disable-next-item
        if (
            principalAssets > 0 && yieldAssets.mulDiv(YIELD_PRECISION, principalAssets) < minYieldPerRequest
        ) revert TooLowYield();

        if (principalAssets > 0) {
            _inConsume = true;
            if (
                IUniversalDelegator(IVaultV2(vault).delegator()).allocateExact(address(this), principalAssets)
                    < principalAssets
            ) revert InsufficientAllocate();

            _inConsume = false;

            IERC20(IERC4626(vault).asset()).forceApprove(msg.sender, principalAssets);
        }

        requests.push(msg.sender);
        requestIndex[msg.sender] = requests.length;
        pendingAssets[msg.sender] = principalAssets;

        emit OnRequestConsumed(msg.sender, offer, principalAssets, yieldAssets);
    }

    /// @inheritdoc IThreeFAdapter
    function finalizeRequest(address request) public nonReentrant {
        uint256 index = requestIndex[request];
        if (index == 0) revert NotRequest();

        IThreeFRequest(request).burnAll(address(this), address(this));

        address lastRequest = requests[requests.length - 1];
        requests.pop();
        requestIndex[request] = 0;
        pendingAssets[request] = 0;
        if (request != lastRequest) {
            requests[index - 1] = lastRequest;
            requestIndex[lastRequest] = index;
        }

        emit FinalizeRequest(request);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Validates that a 3F request is whitelisted and uses the vault asset.
    function _validateRequest(address request) internal view {
        // forgefmt: disable-next-item
        if (
            IThreeFWhitelist(REQUEST_WHITELIST).isWhitelisted(request) != IThreeFWhitelist.WhitelistStatus.Whitelisted
        ) revert NotRequest();

        if (IERC4626(vault).asset() != IThreeFRequest(request).asset()) revert WrongAsset();
    }

    /// @dev Marks just-in-time assets transferred into the adapter as allocated.
    function _allocate(uint256 amount) internal override returns (uint256) {
        return amount;
    }

    /// @dev Live 3F request principal is illiquid until request finalization.
    function _deallocate(uint256) internal override returns (uint256) {
        return 0;
    }
}
