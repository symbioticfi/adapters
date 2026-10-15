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
} from "../../../../interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";
import {IThreeFRequestFactory} from "../../../../interfaces/3f-adapter/IThreeFRequestFactory.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title ThreeFPolicy
/// @notice Migratable contract storing one curator-controlled request funding policy for its consumer.
contract ThreeFPolicy is MigratableEntity, Multicallable, IThreeFPolicy {
    using AssetRateLimits for AssetRateLimits.AssetLimit;

    /* IMMUTABLES */

    /// @inheritdoc IThreeFPolicy
    address public immutable REQUESTS_FACTORY;

    /// @inheritdoc IThreeFPolicy
    address public immutable FACILITY;

    /* STATE VARIABLES */

    /// @inheritdoc IThreeFPolicy
    address public consumer;

    /// @inheritdoc IThreeFPolicy
    mapping(address asset => uint256) public minYieldPerRequest;

    /// @inheritdoc IThreeFPolicy
    mapping(address asset => AssetRateLimits.AssetLimit) public assetLimits;

    /* CONSTRUCTOR */

    constructor(address newFactory, address newRequestsFactory, address newFacility) MigratableEntity(newFactory) {
        REQUESTS_FACTORY = newRequestsFactory;
        FACILITY = newFacility;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IThreeFPolicy
    function remainingAssets(address asset) public view returns (uint256) {
        return assetLimits[asset].remaining();
    }

    /// @inheritdoc IThreeFPolicy
    function setConsumer(address newConsumer) public onlyOwner {
        _setConsumer(newConsumer);
    }

    /// @inheritdoc IThreeFPolicy
    function setMaxAssetsPerDuration(address asset, uint256 newMaxAssets, uint48 newDuration) public onlyOwner {
        assetLimits[asset].configure(newMaxAssets, newDuration);
        emit SetMaxAssetsPerDuration(asset, newMaxAssets, newDuration);
    }

    /// @inheritdoc IThreeFPolicy
    function setMinYieldPerRequest(address asset, uint256 newMinimum) public onlyOwner {
        minYieldPerRequest[asset] = newMinimum;
        emit SetMinYieldPerRequest(asset, newMinimum);
    }

    /// @inheritdoc IThreeFPolicy
    function consume(address request, uint256 assets, uint256 yieldAssets) public {
        if (consumer != msg.sender) revert InvalidCaller();
        if (assets == 0) revert InvalidAssets();
        if (!IThreeFRequestFactory(REQUESTS_FACTORY).isRequest(request)) revert InvalidRequest();

        string memory name = IThreeFRequestName(request).name();
        if (bytes(name).length <= REQUEST_NAME_PREFIX_LENGTH) revert InvalidRequestName();
        (IThreeFFacility.IntentProperties memory properties,, address intentRequest,) =
            IThreeFFacility(FACILITY).getIntent(Strings.parseUint(name, REQUEST_NAME_PREFIX_LENGTH, bytes(name).length));
        if (intentRequest != request) revert RequestMismatch();
        if (!properties.targetAsset.isPositionManager) revert UnsupportedTarget();

        (address collateralAsset,) = IThreeFPositionManager(properties.targetAsset.asset).assets();
        address asset = IThreeFUnderlyingAsset(collateralAsset).underlying();
        if (asset == address(0)) revert InvalidAsset();
        if (yieldAssets * YIELD_PRECISION / assets < minYieldPerRequest[asset]) revert TooLowYield();
        assetLimits[asset].consume(assets);
        emit Consume(asset, assets);
    }

    /* INTERNAL FUNCTIONS */

    function _setConsumer(address newConsumer) internal {
        consumer = newConsumer;
        emit SetConsumer(newConsumer);
    }

    /* INITIALIZATION */

    function _initialize(uint64, address, bytes memory data) internal override {
        _setConsumer(abi.decode(data, (address)));
    }
}
