// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AssetRateLimits} from "../../libraries/AssetRateLimits.sol";

import {
    IThreeFFacility,
    IThreeFPositionManager,
    IThreeFRequestName,
    IThreeFUnderlyingAsset
} from "../../../../interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {
    IThreeFPolicy,
    REQUEST_NAME_PREFIX_LENGTH,
    YIELD_PRECISION
} from "../../../../interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";
import {IThreeFRequestFactory} from "../../../../interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFRequest} from "../../../../interfaces/3f-adapter/IThreeFRequest.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title ThreeFPolicy
/// @notice Migratable contract storing one curator-controlled request funding policy for its bound account.
contract ThreeFPolicy is MigratableEntity, Multicallable, IThreeFPolicy {
    using AssetRateLimits for AssetRateLimits.AssetLimit;

    /* IMMUTABLES */

    /// @inheritdoc IThreeFPolicy
    address public immutable REQUESTS_FACTORY;

    /// @inheritdoc IThreeFPolicy
    address public immutable FACILITY;

    /* STATE VARIABLES */

    /// @inheritdoc IThreeFPolicy
    address public account;

    /// @inheritdoc IThreeFPolicy
    mapping(address underlyingAsset => uint256) public minYieldPerRequest;

    /// @inheritdoc IThreeFPolicy
    mapping(address asset => mapping(address underlyingAsset => AssetRateLimits.AssetLimit)) public assetLimits;

    /* MODIFIERS */

    modifier onlyAccount() {
        if (account != msg.sender) revert InvalidCaller();

        _;
    }

    /* CONSTRUCTOR */

    constructor(address newFactory, address newRequestsFactory, address newFacility) MigratableEntity(newFactory) {
        REQUESTS_FACTORY = newRequestsFactory;
        FACILITY = newFacility;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IThreeFPolicy
    function remainingAssets(address asset, address underlyingAsset) public view returns (uint256) {
        return assetLimits[asset][underlyingAsset].remaining();
    }

    /// @inheritdoc IThreeFPolicy
    function setMaxAssetsPerDuration(address asset, address underlyingAsset, uint256 newMaxAssets, uint48 newDuration)
        public
        onlyAccount
    {
        assetLimits[asset][underlyingAsset].configure(newMaxAssets, newDuration);
        emit SetMaxAssetsPerDuration(asset, underlyingAsset, newMaxAssets, newDuration);
    }

    /// @inheritdoc IThreeFPolicy
    function setMinYieldPerRequest(address underlyingAsset, uint256 newMinimum) public onlyAccount {
        minYieldPerRequest[underlyingAsset] = newMinimum;
        emit SetMinYieldPerRequest(underlyingAsset, newMinimum);
    }

    /// @inheritdoc IThreeFPolicy
    function consume(address request, uint256 assets, uint256 yieldAssets) public onlyAccount {
        if (assets == 0) revert InvalidAssets();
        if (!IThreeFRequestFactory(REQUESTS_FACTORY).isRequest(request)) revert InvalidRequest();

        string memory name = IThreeFRequestName(request).name();
        if (bytes(name).length <= REQUEST_NAME_PREFIX_LENGTH) revert InvalidRequestName();
        (IThreeFFacility.IntentProperties memory properties,, address intentRequest,) =
            IThreeFFacility(FACILITY).getIntent(Strings.parseUint(name, REQUEST_NAME_PREFIX_LENGTH, bytes(name).length));
        if (intentRequest != request) revert RequestMismatch();
        IThreeFFacility.Asset memory position =
            properties.targetAsset.isPositionManager ? properties.targetAsset : properties.depositAsset;
        if (!position.isPositionManager) revert UnsupportedTarget();

        (address collateralAsset,) = IThreeFPositionManager(position.asset).assets();
        address asset = IThreeFRequest(request).asset();
        address underlyingAsset = IThreeFUnderlyingAsset(collateralAsset).underlying();
        if (asset == address(0) || underlyingAsset == address(0)) revert InvalidAsset();
        if (yieldAssets * YIELD_PRECISION / assets < minYieldPerRequest[underlyingAsset]) revert TooLowYield();
        assetLimits[asset][underlyingAsset].consume(assets);
        emit Consume(asset, underlyingAsset, assets);
    }

    /* INTERNAL FUNCTIONS */

    function _initialize(uint64, address, bytes memory data) internal override {
        account = abi.decode(data, (address));
    }
}
