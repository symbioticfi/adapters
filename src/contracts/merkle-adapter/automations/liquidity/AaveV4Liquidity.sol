// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IExecutorLiquidityLens} from "src/interfaces/merkle-adapter/automations/IExecutorLiquidityLens.sol";

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

interface ILiquidityAaveV4Spoke {
    function getReserve(uint256 reserveId)
        external
        view
        returns (address, address, uint16, uint8, uint24, uint8, uint32);
    function getUserSuppliedAssets(uint256 reserveId, address account) external view returns (uint256);
}

interface ILiquidityAaveV4Hub {
    function getAssetLiquidity(uint256 assetId) external view returns (uint256);
    function getSpokeAddedAssets(uint256 assetId, address spoke) external view returns (uint256);
}

/// @title AaveV4Liquidity
/// @notice Scalar calculations for Aave V4 withdrawal liquidity.
/// @dev Uses native share-to-asset conversions without debt or health-factor calculations.
abstract contract AaveV4Liquidity is IExecutorLiquidityLens {
    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IExecutorLiquidityLens
    function aaveV4Withdraw(address spoke, uint256 reserveId, address account) public view returns (uint256) {
        (, address hub, uint16 assetId,,,,) = ILiquidityAaveV4Spoke(spoke).getReserve(reserveId);
        return Math.min(
            ILiquidityAaveV4Spoke(spoke).getUserSuppliedAssets(reserveId, account),
            Math.min(
                ILiquidityAaveV4Hub(hub).getAssetLiquidity(assetId),
                ILiquidityAaveV4Hub(hub).getSpokeAddedAssets(assetId, spoke)
            )
        );
    }
}
