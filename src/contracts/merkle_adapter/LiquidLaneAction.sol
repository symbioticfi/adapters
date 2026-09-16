// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {AssetRateLimits} from "./libraries/AssetRateLimits.sol";

import {IAdapter} from "../../interfaces/IAdapter.sol";
import {IAssetRateLimits} from "../../interfaces/merkle_adapter/IAssetRateLimits.sol";
import {ILiquidLaneAction} from "../../interfaces/merkle_adapter/ILiquidLaneAction.sol";
import {IOracleRegistry} from "../../interfaces/merkle_adapter/IOracleRegistry.sol";
import {IOracle} from "../../interfaces/ll-adapter/IOracle.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title LiquidLaneAction
/// @notice Adapter-bound configuration and pricing action for RWA inventory swaps.
contract LiquidLaneAction is MigratableEntity, ILiquidLaneAction {
    using AssetRateLimits for AssetLimit;
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @inheritdoc ILiquidLaneAction
    address public adapter;

    /// @inheritdoc ILiquidLaneAction
    address public immutable ORACLE_REGISTRY;

    /// @inheritdoc ILiquidLaneAction
    address[] public tokensToRedeem;

    /// @inheritdoc ILiquidLaneAction
    mapping(address tokenToRedeem => address oracle) public oracles;

    /// @dev Tracks whether an RWA token is configured.
    mapping(address tokenToRedeem => bool exists) internal _isTokenToRedeem;

    /// @inheritdoc ILiquidLaneAction
    address public inputAsset;

    /// @inheritdoc IAssetRateLimits
    mapping(address tokenToRedeem => AssetLimit) public assetLimits;

    /// @dev Restricts a function to the bound adapter.
    modifier onlyAdapter() {
        if (msg.sender != adapter) {
            revert InvalidCaller();
        }
        _;
    }

    /// @dev Initializes the immutable factory and oracle registry dependencies.
    constructor(address factory, address oracleRegistry) MigratableEntity(factory) {
        ORACLE_REGISTRY = oracleRegistry;
    }

    /// @inheritdoc ILiquidLaneAction
    function addTokenToRedeem(address tokenToRedeem) public nonReentrant onlyAdapter {
        _addTokenToRedeem(tokenToRedeem);
    }

    /// @inheritdoc ILiquidLaneAction
    function removeTokenToRedeem(address tokenToRedeem) public nonReentrant onlyAdapter {
        uint256 length = tokensToRedeem.length;
        for (uint256 i; i < length; ++i) {
            if (tokensToRedeem[i] == tokenToRedeem) {
                tokensToRedeem[i] = tokensToRedeem[length - 1];
                tokensToRedeem.pop();
                delete _isTokenToRedeem[tokenToRedeem];
                delete oracles[tokenToRedeem];

                emit RemoveTokenToRedeem(tokenToRedeem);
                return;
            }
        }
        revert InvalidTokenToRedeem();
    }

    /// @inheritdoc IAssetRateLimits
    function setMaxAssetsPerDuration(address tokenToRedeem, uint256 maxAssets, uint256 duration)
        public
        nonReentrant
        onlyAdapter
    {
        if (!_isTokenToRedeem[tokenToRedeem]) {
            revert InvalidTokenToRedeem();
        }
        assetLimits[tokenToRedeem].configure(maxAssets, duration);
        emit SetMaxAssetsPerDuration(tokenToRedeem, maxAssets, duration);
    }

    /// @inheritdoc IAssetRateLimits
    function remainingAssets(address tokenToRedeem) public view returns (uint256) {
        return assetLimits[tokenToRedeem].remaining();
    }

    /// @inheritdoc ILiquidLaneAction
    function getTokensToRedeemLength() public view returns (uint256) {
        return tokensToRedeem.length;
    }

    /// @inheritdoc ILiquidLaneAction
    function getAmountOut(address tokenToRedeem, uint256 amountIn) public view returns (uint256) {
        address oracle = oracles[tokenToRedeem];
        if (oracle == address(0)) {
            revert InvalidTokenToRedeem();
        }
        return amountIn.mulDiv(
            IOracle(oracle).getPrice() * 10 ** IERC20Metadata(inputAsset).decimals(),
            1e18 * 10 ** IERC20Metadata(tokenToRedeem).decimals()
        );
    }

    /// @inheritdoc ILiquidLaneAction
    function swap(Swap calldata swap_) public nonReentrant onlyAdapter {
        if (!_isTokenToRedeem[swap_.tokenIn]) {
            revert InvalidTokenToRedeem();
        }
        if (swap_.amountIn > IERC20(swap_.tokenIn).balanceOf(address(this))) {
            revert InsufficientRwaBalance();
        }
        if (swap_.amountOut > getAmountOut(swap_.tokenIn, swap_.amountIn)) {
            revert InvalidSwapRate();
        }

        assetLimits[swap_.tokenIn].consume(swap_.amountOut);

        IERC20(swap_.tokenIn).safeTransfer(adapter, swap_.amountIn);
        IERC20(inputAsset).safeTransferFrom(msg.sender, swap_.recipient, swap_.amountOut);

        emit DoSwap(swap_);
    }

    /// @dev Adds a token using the registry's current approval without resetting its budget.
    function _addTokenToRedeem(address tokenToRedeem) internal {
        if (tokenToRedeem == address(0) || tokenToRedeem == inputAsset || _isTokenToRedeem[tokenToRedeem]) {
            revert InvalidTokenToRedeem();
        }
        address oracle = IOracleRegistry(ORACLE_REGISTRY).oracles(address(this), tokenToRedeem);
        if (oracle == address(0)) {
            revert InvalidOracle();
        }

        oracles[tokenToRedeem] = oracle;
        _isTokenToRedeem[tokenToRedeem] = true;
        tokensToRedeem.push(tokenToRedeem);

        emit AddTokenToRedeem(tokenToRedeem, oracle);
    }

    /// @dev Binds the action proxy to its adapter and funding asset; the initial token list may be empty.
    function _initialize(uint64, address, bytes memory data) internal override {
        (address adapter_, address inputAsset_, address[] memory tokensToRedeem_) =
            abi.decode(data, (address, address, address[]));
        if (adapter_ == address(0)) {
            revert InvalidAdapter();
        }
        if (inputAsset_ == address(0)) {
            revert InvalidInputAsset();
        }
        adapter = adapter_;
        inputAsset = inputAsset_;

        for (uint256 i; i < tokensToRedeem_.length; ++i) {
            _addTokenToRedeem(tokensToRedeem_[i]);
        }
    }

    /// @dev Allows state-preserving implementation upgrades without reconfiguration.
    function _migrate(uint64, uint64, bytes calldata data) internal override {
        if (data.length != 0) {
            revert InvalidMigrationData();
        }
        if (inputAsset == address(0)) {
            inputAsset = IERC4626(IAdapter(adapter).vault()).asset();
        }
    }
}
