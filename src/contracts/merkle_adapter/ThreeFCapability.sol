// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {IAdapter} from "../../interfaces/IAdapter.sol";
import {IThreeFCapability, MAX_REQUESTS} from "../../interfaces/merkle_adapter/IThreeFCapability.sol";
import {IThreeFRequestCallback} from "../../interfaces/3f-adapter/IThreeFRequestCallback.sol";
import {IThreeFRequest} from "../../interfaces/3f-adapter/IThreeFRequest.sol";
import {IThreeFWhitelist} from "../../interfaces/3f-adapter/IThreeFWhitelist.sol";
import {Offer, YIELD_PRECISION} from "../../interfaces/3f-adapter/ThreeFTypes.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title ThreeFCapability
/// @notice Adapter-bound capability for 3F bridge facilitator requests.
contract ThreeFCapability is MigratableEntity, IThreeFCapability {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @inheritdoc IThreeFCapability
    address public immutable REQUEST_WHITELIST;

    /// @inheritdoc IThreeFCapability
    address public adapter;

    /// @inheritdoc IThreeFCapability
    address public offerSigner;

    /// @inheritdoc IThreeFCapability
    uint256 public minYieldPerRequest;

    /// @inheritdoc IThreeFCapability
    uint256 public minAssetsPerRequest;

    /// @inheritdoc IThreeFCapability
    uint256 public maxAssetsPerRequest;

    /// @inheritdoc IThreeFCapability
    address[] public requests;

    /// @inheritdoc IThreeFCapability
    mapping(address request => uint256 index) public requestIndex;

    /// @inheritdoc IThreeFCapability
    mapping(address request => uint256 assets) public pendingAssets;

    /// @dev Restricts a function to the bound adapter.
    modifier onlyAdapter() {
        if (msg.sender != adapter) {
            revert InvalidCaller();
        }
        _;
    }

    /// @dev Initializes the immutable factory and request whitelist dependencies.
    constructor(address factory, address requestWhitelist) MigratableEntity(factory) {
        REQUEST_WHITELIST = requestWhitelist;
    }

    /// @inheritdoc IThreeFCapability
    function setOfferSigner(address newOfferSigner) public onlyAdapter {
        offerSigner = newOfferSigner;

        emit SetOfferSigner(newOfferSigner);
    }

    /// @inheritdoc IThreeFCapability
    function setLimitsPerRequest(
        uint256 newMinYieldPerRequest,
        uint256 newMinAssetsPerRequest,
        uint256 newMaxAssetsPerRequest
    ) public onlyAdapter {
        minYieldPerRequest = newMinYieldPerRequest;
        minAssetsPerRequest = newMinAssetsPerRequest;
        maxAssetsPerRequest = newMaxAssetsPerRequest;

        emit SetLimitsPerRequest(newMinYieldPerRequest, newMinAssetsPerRequest, newMaxAssetsPerRequest);
    }

    /// @inheritdoc IThreeFCapability
    function setRequestNonce(address request, uint256 newNonce) public onlyAdapter {
        _validateRequest(request);

        IThreeFRequest(request).setNonce(newNonce);

        emit SetRequestNonce(request, newNonce);
    }

    /// @inheritdoc IThreeFRequestCallback
    function onRequestConsumed(Offer calldata offer, bytes calldata, uint256 principalAssets, uint256 yieldAssets)
        public
        nonReentrant
    {
        _validateRequest(msg.sender);

        if (offer.maker != address(this) || !offer.useCallback || offer.expectedReturn == 0) {
            revert InvalidOffer();
        }
        if (offer.expiration < block.timestamp) {
            revert ExpiredOffer();
        }
        if (requests.length >= MAX_REQUESTS) {
            revert TooManyRequests();
        }
        if (requestIndex[msg.sender] > 0) {
            revert AlreadyRequest();
        }
        if (principalAssets < minAssetsPerRequest) {
            revert TooSmallRequest();
        }
        if (principalAssets > maxAssetsPerRequest) {
            revert TooLargeRequest();
        }
        if (principalAssets > 0 && yieldAssets.mulDiv(YIELD_PRECISION, principalAssets) < minYieldPerRequest) {
            revert TooLowYield();
        }

        if (principalAssets > 0) {
            IERC20 asset = IERC20(IERC4626(IAdapter(adapter).vault()).asset());
            asset.safeTransferFrom(adapter, address(this), principalAssets);
            asset.forceApprove(msg.sender, principalAssets);
        }

        requests.push(msg.sender);
        requestIndex[msg.sender] = requests.length;
        pendingAssets[msg.sender] = principalAssets;

        emit OnRequestConsumed(msg.sender, offer, principalAssets, yieldAssets);
    }

    /// @inheritdoc IThreeFCapability
    function finalizeRequest(address request) public nonReentrant {
        uint256 index = requestIndex[request];
        if (index == 0) {
            revert NotRequest();
        }

        (,, uint256 pAssets, uint256 yAssets) = IThreeFRequest(request).burnAll(address(this), address(this));

        address lastRequest = requests[requests.length - 1];
        requests.pop();
        requestIndex[request] = 0;
        pendingAssets[request] = 0;
        if (request != lastRequest) {
            requests[index - 1] = lastRequest;
            requestIndex[lastRequest] = index;
        }

        IERC20(IERC4626(IAdapter(adapter).vault()).asset()).safeTransfer(adapter, pAssets + yAssets);

        emit FinalizeRequest(request);
    }

    /// @inheritdoc IThreeFCapability
    function isValidSignature(bytes32 hash, bytes calldata signature) public view returns (bytes4) {
        return SignatureChecker.isValidSignatureNowCalldata(offerSigner, hash, signature)
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }

    /// @inheritdoc IThreeFCapability
    function requestsLength() public view returns (uint256) {
        return requests.length;
    }

    /// @inheritdoc IThreeFCapability
    function totalAssets() public view returns (uint256 assets) {
        assets = IERC20(IERC4626(IAdapter(adapter).vault()).asset()).balanceOf(address(this));
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

    /// @dev Binds the capability proxy to its adapter.
    function _initialize(uint64, address, bytes memory data) internal override {
        adapter = abi.decode(data, (address));
    }

    /// @dev Allows state-preserving implementation upgrades without reconfiguration.
    function _migrate(uint64, uint64, bytes calldata data) internal pure override {
        if (data.length != 0) {
            revert InvalidMigrationData();
        }
    }

    /// @dev Validates that a 3F request is whitelisted and uses the adapter vault asset.
    function _validateRequest(address request) internal view {
        if (IThreeFWhitelist(REQUEST_WHITELIST).isWhitelisted(request) != IThreeFWhitelist.WhitelistStatus.Whitelisted)
        {
            revert NotRequest();
        }

        if (IERC4626(IAdapter(adapter).vault()).asset() != IThreeFRequest(request).asset()) {
            revert WrongAsset();
        }
    }
}
