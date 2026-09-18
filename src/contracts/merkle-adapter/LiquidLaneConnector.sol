// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AssetRateLimits} from "./libraries/AssetRateLimits.sol";

import {IAssetRateLimits} from "../../interfaces/merkle-adapter/IAssetRateLimits.sol";
import {ILiquidLaneConnector} from "../../interfaces/merkle-adapter/ILiquidLaneConnector.sol";
import {IOracleRegistry} from "../../interfaces/merkle-adapter/IOracleRegistry.sol";
import {IOracle} from "../../interfaces/ll-adapter/IOracle.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title LiquidLaneConnector
/// @notice Contract for adapter-bound RWA inventory swaps with saved oracles and asset budgets.
contract LiquidLaneConnector is MigratableEntity, ILiquidLaneConnector {
    using AssetRateLimits for AssetLimit;
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc ILiquidLaneConnector
    address public immutable ORACLE_REGISTRY;

    /* STATE VARIABLES */

    /// @inheritdoc ILiquidLaneConnector
    address public adapter;

    /// @inheritdoc ILiquidLaneConnector
    address[] public tokensToRedeem;

    /// @inheritdoc ILiquidLaneConnector
    mapping(address tokenToRedeem => address oracle) public oracles;

    /// @inheritdoc ILiquidLaneConnector
    address public inputAsset;

    /// @inheritdoc IAssetRateLimits
    mapping(address tokenToRedeem => AssetLimit) public assetLimits;

    /* MODIFIERS */

    /// @dev Restricts a function to the bound adapter.
    modifier onlyAdapter() {
        if (adapter != msg.sender) revert InvalidCaller();

        _;
    }

    /* CONSTRUCTOR */

    /// @dev Initializes the immutable factory and oracle registry dependencies.
    constructor(address newFactory, address newOracleRegistry) MigratableEntity(newFactory) {
        ORACLE_REGISTRY = newOracleRegistry;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ILiquidLaneConnector
    function addTokenToRedeem(address tokenToRedeem) public nonReentrant onlyAdapter {
        _addTokenToRedeem(tokenToRedeem);
    }

    /// @inheritdoc ILiquidLaneConnector
    function removeTokenToRedeem(address tokenToRedeem) public nonReentrant onlyAdapter {
        uint256 length = tokensToRedeem.length;
        for (uint256 i; i < length; ++i) {
            if (tokensToRedeem[i] == tokenToRedeem) {
                tokensToRedeem[i] = tokensToRedeem[length - 1];
                tokensToRedeem.pop();
                delete oracles[tokenToRedeem];

                emit RemoveTokenToRedeem(tokenToRedeem);
                return;
            }
        }
        revert InvalidTokenToRedeem();
    }

    /// @inheritdoc IAssetRateLimits
    function setMaxAssetsPerDuration(address tokenToRedeem, uint256 newMaxAssets, uint256 newDuration)
        public
        nonReentrant
        onlyAdapter
    {
        if (oracles[tokenToRedeem] == address(0)) revert InvalidTokenToRedeem();

        assetLimits[tokenToRedeem].configure(newMaxAssets, newDuration);
        emit SetMaxAssetsPerDuration(tokenToRedeem, newMaxAssets, newDuration);
    }

    /// @inheritdoc IAssetRateLimits
    function remainingAssets(address tokenToRedeem) public view returns (uint256) {
        return assetLimits[tokenToRedeem].remaining();
    }

    /// @inheritdoc ILiquidLaneConnector
    function getTokensToRedeemLength() public view returns (uint256) {
        return tokensToRedeem.length;
    }

    /// @inheritdoc ILiquidLaneConnector
    function getAmountOut(address tokenToRedeem, uint256 amountIn) public view returns (uint256) {
        address oracle = oracles[tokenToRedeem];
        if (oracle == address(0)) revert InvalidTokenToRedeem();

        return amountIn.mulDiv(
            IOracle(oracle).getPrice() * 10 ** IERC20Metadata(inputAsset).decimals(),
            1e18 * 10 ** IERC20Metadata(tokenToRedeem).decimals()
        );
    }

    /// @inheritdoc ILiquidLaneConnector
    function swap(Swap calldata newSwap) public nonReentrant onlyAdapter {
        if (oracles[newSwap.tokenIn] == address(0)) revert InvalidTokenToRedeem();

        if (newSwap.amountIn > IERC20(newSwap.tokenIn).balanceOf(address(this))) revert InsufficientRwaBalance();

        if (newSwap.amountOut > getAmountOut(newSwap.tokenIn, newSwap.amountIn)) revert InvalidSwapRate();

        assetLimits[newSwap.tokenIn].consume(newSwap.amountOut);

        IERC20(newSwap.tokenIn).safeTransfer(adapter, newSwap.amountIn);
        IERC20(inputAsset).safeTransferFrom(msg.sender, newSwap.recipient, newSwap.amountOut);

        emit DoSwap(newSwap);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Adds a token using the registry's current approval without resetting its budget.
    function _addTokenToRedeem(address tokenToRedeem) internal {
        if (tokenToRedeem == address(0) || tokenToRedeem == inputAsset || oracles[tokenToRedeem] != address(0)) {
            revert InvalidTokenToRedeem();
        }

        address oracle = IOracleRegistry(ORACLE_REGISTRY).oracles(address(this), tokenToRedeem);
        if (oracle == address(0)) revert InvalidOracle();

        oracles[tokenToRedeem] = oracle;
        tokensToRedeem.push(tokenToRedeem);

        emit AddTokenToRedeem(tokenToRedeem, oracle);
    }

    /// @dev Binds the connector proxy to its adapter and funding asset; the initial token list may be empty.
    function _initialize(uint64, address, bytes memory data) internal override {
        (address newAdapter, address newInputAsset, address[] memory newTokensToRedeem) =
            abi.decode(data, (address, address, address[]));
        if (newAdapter == address(0)) revert InvalidAdapter();

        if (newInputAsset == address(0)) revert InvalidInputAsset();

        adapter = newAdapter;
        inputAsset = newInputAsset;

        for (uint256 i; i < newTokensToRedeem.length; ++i) {
            _addTokenToRedeem(newTokensToRedeem[i]);
        }
    }

    /// @dev Allows state-preserving implementation upgrades without reconfiguration.
    function _migrate(uint64, uint64, bytes calldata data) internal pure override {
        if (data.length != 0) revert InvalidMigrationData();
    }
}
