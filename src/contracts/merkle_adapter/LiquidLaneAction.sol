// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {AssetRateLimits} from "./libraries/AssetRateLimits.sol";

import {IAdapter} from "../../interfaces/IAdapter.sol";
import {IAssetRateLimits} from "../../interfaces/merkle_adapter/IAssetRateLimits.sol";
import {ILiquidLaneAction} from "../../interfaces/merkle_adapter/ILiquidLaneAction.sol";
import {IOracle} from "../../interfaces/ll-adapter/IOracle.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title LiquidLaneAction
/// @notice Adapter-bound RWA inventory swaps with implementation-defined assets and price oracles.
/// @dev Implementations must override oracle() using constants or constructor immutables, with prices in inputAsset().
abstract contract LiquidLaneAction is MigratableEntity, ILiquidLaneAction {
    using AssetRateLimits for AssetLimit;
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @inheritdoc ILiquidLaneAction
    address public adapter;

    /// @dev Funding asset fixed for every proxy using this implementation.
    address private immutable _INPUT_ASSET;

    /// @dev Reserved slots from registry-configured versions. Never used to authorize or price an asset.
    address[] private __deprecatedTokensToRedeem;
    mapping(address tokenToRedeem => address oracle_) private __deprecatedOracles;
    mapping(address tokenToRedeem => bool exists) private __deprecatedIsTokenToRedeem;

    /// @dev Preserves the funding denomination across migrations.
    address private _inputAsset;

    /// @inheritdoc IAssetRateLimits
    mapping(address tokenToRedeem => AssetLimit) public assetLimits;

    /// @dev Restricts a function to the bound adapter.
    modifier onlyAdapter() {
        if (msg.sender != adapter) {
            revert InvalidCaller();
        }
        _;
    }

    /// @dev Fixes the factory and funding denomination for the implementation's oracles.
    constructor(address factory, address inputAsset_) MigratableEntity(factory) {
        if (inputAsset_ == address(0)) {
            revert InvalidInputAsset();
        }
        _INPUT_ASSET = inputAsset_;
    }

    /// @inheritdoc IAssetRateLimits
    function setMaxAssetsPerDuration(address tokenToRedeem, uint256 maxAssets, uint256 duration)
        public
        nonReentrant
        onlyAdapter
    {
        _getOracle(tokenToRedeem);
        assetLimits[tokenToRedeem].configure(maxAssets, duration);
        emit SetMaxAssetsPerDuration(tokenToRedeem, maxAssets, duration);
    }

    /// @inheritdoc IAssetRateLimits
    function remainingAssets(address tokenToRedeem) public view returns (uint256) {
        return assetLimits[tokenToRedeem].remaining();
    }

    /// @inheritdoc ILiquidLaneAction
    function inputAsset() public view returns (address) {
        return _INPUT_ASSET;
    }

    /// @inheritdoc ILiquidLaneAction
    function oracle(address tokenToRedeem) public view virtual returns (address);

    /// @inheritdoc ILiquidLaneAction
    function getAmountOut(address tokenToRedeem, uint256 amountIn) public view returns (uint256) {
        return amountIn.mulDiv(
            IOracle(_getOracle(tokenToRedeem)).getPrice() * 10 ** IERC20Metadata(_INPUT_ASSET).decimals(),
            1e18 * 10 ** IERC20Metadata(tokenToRedeem).decimals()
        );
    }

    /// @inheritdoc ILiquidLaneAction
    function swap(Swap calldata swap_) public nonReentrant onlyAdapter {
        uint256 maximumAmountOut = getAmountOut(swap_.tokenIn, swap_.amountIn);
        if (swap_.amountIn > IERC20(swap_.tokenIn).balanceOf(address(this))) {
            revert InsufficientRwaBalance();
        }
        if (swap_.amountOut > maximumAmountOut) {
            revert InvalidSwapRate();
        }

        assetLimits[swap_.tokenIn].consume(swap_.amountOut);

        IERC20(swap_.tokenIn).safeTransfer(adapter, swap_.amountIn);
        IERC20(_INPUT_ASSET).safeTransferFrom(msg.sender, swap_.recipient, swap_.amountOut);

        emit DoSwap(swap_);
    }

    /// @dev Binds a proxy to its adapter. Asset and oracle configuration belongs to the implementation.
    function _initialize(uint64, address, bytes memory data) internal override {
        if (data.length != 32) {
            revert InvalidInitializationData();
        }
        address adapter_ = abi.decode(data, (address));
        if (adapter_ == address(0)) {
            revert InvalidAdapter();
        }
        adapter = adapter_;
        _inputAsset = _INPUT_ASSET;
    }

    /// @dev Allows state-preserving implementation upgrades without reconfiguration.
    function _migrate(uint64, uint64, bytes calldata data) internal override {
        if (data.length != 0) {
            revert InvalidMigrationData();
        }
        if (_inputAsset == address(0)) {
            _inputAsset = IERC4626(IAdapter(adapter).vault()).asset();
        }
        if (_inputAsset != _INPUT_ASSET) {
            revert InvalidInputAsset();
        }
    }

    /// @dev A nonzero implementation-defined oracle authorizes an RWA token.
    function _getOracle(address tokenToRedeem) internal view returns (address oracle_) {
        if (tokenToRedeem == address(0) || tokenToRedeem == _INPUT_ASSET) {
            revert InvalidTokenToRedeem();
        }
        oracle_ = oracle(tokenToRedeem);
        if (oracle_ == address(0)) {
            revert InvalidTokenToRedeem();
        }
    }
}
