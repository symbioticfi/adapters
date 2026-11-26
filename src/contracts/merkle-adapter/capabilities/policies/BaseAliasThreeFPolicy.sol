// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AssetRateLimits} from "../../libraries/AssetRateLimits.sol";

import {
    IBaseAliasThreeFPolicy
} from "../../../../interfaces/merkle-adapter/capabilities/policies/IBaseAliasThreeFPolicy.sol";
import {YIELD_PRECISION} from "../../../../interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BaseAliasThreeFPolicy
/// @notice Ethereum policy for dispatching Base 3F mints from a MerkleAccount's alias.
contract BaseAliasThreeFPolicy is IBaseAliasThreeFPolicy {
    using AssetRateLimits for AssetRateLimits.AssetLimit;
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IBaseAliasThreeFPolicy
    address public immutable account;

    /* STATE VARIABLES */

    /// @inheritdoc IBaseAliasThreeFPolicy
    mapping(address request => address) public requestUnderlying;

    /// @inheritdoc IBaseAliasThreeFPolicy
    mapping(address underlyingAsset => uint256) public minYieldPerRequest;

    mapping(address underlyingAsset => AssetRateLimits.AssetLimit) private _assetLimits;

    /* MODIFIERS */

    modifier onlyAccount() {
        if (account != msg.sender) revert InvalidCaller();

        _;
    }

    /* CONSTRUCTOR */

    constructor(address newAccount) {
        if (newAccount == address(0)) revert InvalidCaller();
        account = newAccount;
    }

    /* EXTERNAL FUNCTIONS */

    /// @inheritdoc IBaseAliasThreeFPolicy
    function remainingAssets(address underlyingAsset) external view returns (uint256) {
        return _assetLimits[underlyingAsset].remaining();
    }

    /// @inheritdoc IBaseAliasThreeFPolicy
    function setRequestUnderlying(address request, address underlyingAsset) external onlyAccount {
        if (request == address(0)) revert InvalidRequest();
        requestUnderlying[request] = underlyingAsset;
        emit SetRequestUnderlying(request, underlyingAsset);
    }

    /// @inheritdoc IBaseAliasThreeFPolicy
    function setMaxAssetsPerDuration(address underlyingAsset, uint256 maxAssets, uint48 duration) external onlyAccount {
        _assetLimits[underlyingAsset].configure(maxAssets, duration);
        emit SetMaxAssetsPerDuration(underlyingAsset, maxAssets, duration);
    }

    /// @inheritdoc IBaseAliasThreeFPolicy
    function setMinYieldPerRequest(address underlyingAsset, uint256 minimum) external onlyAccount {
        minYieldPerRequest[underlyingAsset] = minimum;
        emit SetMinYieldPerRequest(underlyingAsset, minimum);
    }

    /// @inheritdoc IBaseAliasThreeFPolicy
    function consume(address request, uint256 maxPrincipal, uint256 minYield) external onlyAccount {
        if (maxPrincipal == 0) revert InvalidAssets();
        address underlyingAsset = requestUnderlying[request];
        if (underlyingAsset == address(0)) revert InvalidRequest();
        if (minYield.mulDiv(YIELD_PRECISION, maxPrincipal) < minYieldPerRequest[underlyingAsset]) revert TooLowYield();
        _assetLimits[underlyingAsset].consume(maxPrincipal);
        emit Consume(request, underlyingAsset, maxPrincipal, minYield);
    }
}
