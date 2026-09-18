// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Capability} from "./Capability.sol";

import {AssetRateLimits} from "../libraries/AssetRateLimits.sol";

import {IAdapter} from "../../../interfaces/IAdapter.sol";
import {IAssetRateLimits} from "../../../interfaces/merkle-adapter/IAssetRateLimits.sol";
import {
    IThreeFCapability,
    MAX_REQUESTS,
    REQUEST_NAME_PREFIX,
    REQUEST_NAME_PREFIX_LENGTH
} from "../../../interfaces/merkle-adapter/capabilities/IThreeFCapability.sol";
import {
    IThreeFFacility,
    IThreeFPositionManager,
    IThreeFRequestName,
    IThreeFUnderlyingAsset
} from "../../../interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {IThreeFPushRequest} from "../../../interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequest} from "../../../interfaces/3f-adapter/IThreeFRequest.sol";
import {IThreeFWhitelist} from "../../../interfaces/3f-adapter/IThreeFWhitelist.sol";
import {YIELD_PRECISION} from "../../../interfaces/3f-adapter/ThreeFTypes.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title ThreeFCapability
/// @notice Contract for adapter-context 3F push minting with collateral-specific funding budgets and minimum yields.
contract ThreeFCapability layout at erc7201("symbiotic.storage.ThreeFCapability") is Capability, IThreeFCapability {
    using AssetRateLimits for AssetLimit;
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IThreeFCapability
    address public immutable REQUEST_WHITELIST;

    /// @inheritdoc IThreeFCapability
    address public immutable FACILITY;

    /* STATE VARIABLES */

    /// @inheritdoc IThreeFCapability
    address[] public requests;

    /// @inheritdoc IThreeFCapability
    mapping(address request => uint256 index) public requestIndex;

    /// @inheritdoc IThreeFCapability
    mapping(address request => uint256 assets) public pendingAssets;

    /// @inheritdoc IThreeFCapability
    mapping(address asset => uint256 minimum) public minYieldPerRequest;

    /// @inheritdoc IAssetRateLimits
    mapping(address asset => AssetLimit limit) public assetLimits;

    /* CONSTRUCTOR */

    /// @dev Binds the request whitelist and trusted 3F facility in the approved implementation.
    constructor(address newRequestWhitelist, address newFacility) {
        REQUEST_WHITELIST = newRequestWhitelist;
        FACILITY = newFacility;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IThreeFCapability
    function setMinYieldPerRequest(address asset, uint256 newMinimum) public onlyMyself {
        minYieldPerRequest[asset] = newMinimum;
        emit SetMinYieldPerRequest(asset, newMinimum);
    }

    /// @inheritdoc IAssetRateLimits
    function setMaxAssetsPerDuration(address asset, uint256 newMaxAssets, uint256 newDuration) public onlyMyself {
        assetLimits[asset].configure(newMaxAssets, newDuration);
        emit SetMaxAssetsPerDuration(asset, newMaxAssets, newDuration);
    }

    /// @inheritdoc IAssetRateLimits
    function remainingAssets(address asset) public view returns (uint256) {
        return assetLimits[asset].remaining();
    }

    /// @inheritdoc IThreeFCapability
    function mintRequest(address request, uint128 maxPrincipalAssets, uint128 minYieldAssets, uint256 deadline)
        public
        onlyMyself
    {
        if (block.timestamp > deadline) revert MintDeadlineExpired();

        if (IThreeFWhitelist(REQUEST_WHITELIST).isWhitelisted(request) != IThreeFWhitelist.WhitelistStatus.Whitelisted) revert NotRequest();

        if (IERC4626(IAdapter(address(this)).vault()).asset() != IThreeFRequest(request).asset()) revert WrongAsset();
        if (requests.length >= MAX_REQUESTS) revert TooManyRequests();

        if (requestIndex[request] > 0) revert AlreadyRequest();

        address underlying;
        {
            bytes memory requestName = bytes(IThreeFRequestName(request).name());
            if (
                requestName.length <= REQUEST_NAME_PREFIX_LENGTH
                    || !Bytes.equal(Bytes.slice(requestName, 0, REQUEST_NAME_PREFIX_LENGTH), REQUEST_NAME_PREFIX)
            ) revert InvalidRequestName();

            (bool valid, uint256 id) =
                Strings.tryParseUint(string(requestName), REQUEST_NAME_PREFIX_LENGTH, requestName.length);
            if (!valid) revert InvalidRequestName();

            (IThreeFFacility.IntentProperties memory properties,, address intentRequest,) =
                IThreeFFacility(FACILITY).getIntent(id);
            if (intentRequest != request) revert RequestMismatch();

            if (!properties.targetAsset.isPositionManager) revert UnsupportedTarget();

            (address collateralAsset,) = IThreeFPositionManager(properties.targetAsset.asset).assets();
            underlying = IThreeFUnderlyingAsset(collateralAsset).underlying();
        }
        if (assetLimits[underlying].maxAssets == 0) revert UnconfiguredAsset();

        (uint128 principalAssets, uint128 yieldAssets) = IThreeFPushRequest(request).mintAuthorization(address(this));
        if (principalAssets == 0 || yieldAssets == 0) revert InvalidMintAuthorization();

        if (principalAssets > maxPrincipalAssets || yieldAssets < minYieldAssets) revert SlippageExceeded();

        if (uint256(yieldAssets).mulDiv(YIELD_PRECISION, principalAssets) < minYieldPerRequest[underlying]) {
            revert TooLowYield();
        }

        assetLimits[underlying].consume(principalAssets);

        address asset = IERC4626(IAdapter(address(this)).vault()).asset();
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        if (balanceBefore < principalAssets) revert InvalidMintAuthorization();

        IThreeFPushRequest(request).mint(principalAssets, yieldAssets);
        if (IERC20(asset).balanceOf(address(this)) != balanceBefore - principalAssets) {
            revert InvalidMintAuthorization();
        }

        requests.push(request);
        requestIndex[request] = requests.length;
        pendingAssets[request] = principalAssets;

        emit MintRequest(request, underlying, principalAssets, yieldAssets);
    }

    /// @inheritdoc IThreeFCapability
    function finalizeRequest(address request) public onlyMyself {
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

    /// @inheritdoc IThreeFCapability
    function requestsLength() public view returns (uint256) {
        return requests.length;
    }

    /// @inheritdoc IThreeFCapability
    function threeFPositionAssets() public view returns (uint256 assets) {
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
}
