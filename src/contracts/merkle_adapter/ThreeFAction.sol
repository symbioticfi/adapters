// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {IAdapter} from "../../interfaces/IAdapter.sol";
import {
    IThreeFAction,
    MAX_REQUESTS,
    REQUEST_NAME_PREFIX,
    REQUEST_NAME_PREFIX_LENGTH
} from "../../interfaces/merkle_adapter/IThreeFAction.sol";
import {
    IThreeFFacility,
    IThreeFPositionManager,
    IThreeFRequestName,
    IThreeFUnderlyingAsset
} from "../../interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {IThreeFPushRequest} from "../../interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequest} from "../../interfaces/3f-adapter/IThreeFRequest.sol";
import {IThreeFWhitelist} from "../../interfaces/3f-adapter/IThreeFWhitelist.sol";
import {YIELD_PRECISION} from "../../interfaces/3f-adapter/ThreeFTypes.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title ThreeFAction
/// @notice Adapter-controlled 3F push minting with collateral-specific request limits.
contract ThreeFAction is MigratableEntity, IThreeFAction {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @inheritdoc IThreeFAction
    address public immutable REQUEST_WHITELIST;

    /// @inheritdoc IThreeFAction
    address public immutable FACILITY;

    /// @inheritdoc IThreeFAction
    address public adapter;

    /// @dev Reserves the legacy offer-signer slot; push minting has no signature-based funding path.
    address private __deprecatedOfferSigner;

    /// @dev Reserves the three legacy global-limit slots, preserving active request storage on upgrade.
    uint256[3] private __gap;

    /// @inheritdoc IThreeFAction
    address[] public requests;

    /// @inheritdoc IThreeFAction
    mapping(address request => uint256 index) public requestIndex;

    /// @inheritdoc IThreeFAction
    mapping(address request => uint256 assets) public pendingAssets;

    /// @inheritdoc IThreeFAction
    mapping(address asset => Limits) public limits;

    /// @dev Restricts configuration and push execution to the bound adapter.
    modifier onlyAdapter() {
        if (msg.sender != adapter) {
            revert InvalidCaller();
        }
        _;
    }

    /// @dev Binds the action factory, request whitelist, and trusted 3F facility.
    constructor(address factory, address requestWhitelist, address facility) MigratableEntity(factory) {
        REQUEST_WHITELIST = requestWhitelist;
        FACILITY = facility;
    }

    /// @inheritdoc IThreeFAction
    function setLimitsPerRequest(
        address asset,
        uint256 newMinYieldPerRequest,
        uint256 newMinAssetsPerRequest,
        uint256 newMaxAssetsPerRequest
    ) public onlyAdapter {
        limits[asset] = Limits({
            minYieldPerRequest: newMinYieldPerRequest,
            minAssetsPerRequest: newMinAssetsPerRequest,
            maxAssetsPerRequest: newMaxAssetsPerRequest
        });

        emit SetLimitsPerRequest(asset, newMinYieldPerRequest, newMinAssetsPerRequest, newMaxAssetsPerRequest);
    }

    /// @inheritdoc IThreeFAction
    function mintRequest(address request, uint128 maxPrincipalAssets, uint128 minYieldAssets, uint256 deadline)
        public
        nonReentrant
        onlyAdapter
    {
        if (block.timestamp > deadline) {
            revert MintDeadlineExpired();
        }
        _validateRequest(request);
        if (requests.length >= MAX_REQUESTS) {
            revert TooManyRequests();
        }
        if (requestIndex[request] > 0) {
            revert AlreadyRequest();
        }

        address underlying = _requestUnderlying(request);
        Limits memory assetLimits = limits[underlying];
        if (assetLimits.maxAssetsPerRequest == 0) {
            revert UnconfiguredAsset();
        }
        (uint128 principalAssets, uint128 yieldAssets) = IThreeFPushRequest(request).mintAuthorization(address(this));
        if (principalAssets == 0 || yieldAssets == 0) {
            revert InvalidMintAuthorization();
        }
        if (principalAssets > maxPrincipalAssets || yieldAssets < minYieldAssets) {
            revert SlippageExceeded();
        }
        if (principalAssets < assetLimits.minAssetsPerRequest) {
            revert TooSmallRequest();
        }
        if (principalAssets > assetLimits.maxAssetsPerRequest) {
            revert TooLargeRequest();
        }
        if (uint256(yieldAssets).mulDiv(YIELD_PRECISION, principalAssets) < assetLimits.minYieldPerRequest) {
            revert TooLowYield();
        }

        IERC20 asset = IERC20(IERC4626(IAdapter(adapter).vault()).asset());
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(adapter, address(this), principalAssets);
        asset.forceApprove(request, principalAssets);
        IThreeFPushRequest(request).mint(principalAssets, yieldAssets);
        asset.forceApprove(request, 0);
        if (asset.balanceOf(address(this)) != balanceBefore) {
            revert InvalidMintAuthorization();
        }

        requests.push(request);
        requestIndex[request] = requests.length;
        pendingAssets[request] = principalAssets;

        emit MintRequest(request, underlying, principalAssets, yieldAssets);
    }

    /// @inheritdoc IThreeFAction
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

    /// @inheritdoc IThreeFAction
    function requestsLength() public view returns (uint256) {
        return requests.length;
    }

    /// @inheritdoc IThreeFAction
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

    /// @dev Validates funding-asset compatibility and the request's active whitelist status.
    function _validateRequest(address request) internal view {
        if (IThreeFWhitelist(REQUEST_WHITELIST).isWhitelisted(request) != IThreeFWhitelist.WhitelistStatus.Whitelisted)
        {
            revert NotRequest();
        }
        if (IERC4626(IAdapter(adapter).vault()).asset() != IThreeFRequest(request).asset()) {
            revert WrongAsset();
        }
    }

    /// @dev Resolves collateral through the trusted facility, binding the parsed intent to this exact request.
    function _requestUnderlying(address request) internal view returns (address) {
        bytes memory requestName = bytes(IThreeFRequestName(request).name());
        if (requestName.length <= REQUEST_NAME_PREFIX_LENGTH) {
            revert InvalidRequestName();
        }
        if (!Bytes.equal(Bytes.slice(requestName, 0, REQUEST_NAME_PREFIX_LENGTH), REQUEST_NAME_PREFIX)) {
            revert InvalidRequestName();
        }
        (bool valid, uint256 id) =
            Strings.tryParseUint(string(requestName), REQUEST_NAME_PREFIX_LENGTH, requestName.length);
        if (!valid) {
            revert InvalidRequestName();
        }
        (IThreeFFacility.IntentProperties memory properties,, address intentRequest,) =
            IThreeFFacility(FACILITY).getIntent(id);
        if (intentRequest != request) {
            revert RequestMismatch();
        }
        if (!properties.targetAsset.isPositionManager) {
            revert UnsupportedTarget();
        }
        (address collateralAsset,) = IThreeFPositionManager(properties.targetAsset.asset).assets();
        return IThreeFUnderlyingAsset(collateralAsset).underlying();
    }

    /// @dev Binds the action proxy to its adapter; collateral limits are configured separately.
    function _initialize(uint64, address, bytes memory data) internal override {
        adapter = abi.decode(data, (address));
    }

    /// @dev Preserves legacy positions and reserves their storage slots. New per-asset limits start disabled.
    function _migrate(uint64, uint64, bytes calldata data) internal pure override {
        if (data.length != 0) {
            revert InvalidMigrationData();
        }
    }
}
