// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IAaveV4Liquidity} from "../../../../interfaces/merkle-adapter/automations/liquidity/IAaveV4Liquidity.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
/// Stateless and permissionless: the query returns underlying token units for the explicitly
/// encoded account, never msg.sender. Failed reads revert and cannot authorize any funding call.
/// RecipeExecutor still enforces the actual balance delta, current Merkle proof and role on every
/// used source. Deploy through ImmutableFactory(type(AaveV4Liquidity).creationCode).create("").
/// @custom:security-contact https://github.com/symbioticfi/adapters/security
contract AaveV4Liquidity is IAaveV4Liquidity {
    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IAaveV4Liquidity
    function liquidity(address spoke, uint256 reserveId, address account) public view returns (uint256) {
        (, address hub, uint16 assetId,,,,) = ILiquidityAaveV4Spoke(spoke).getReserve(reserveId);
        return Math.min(
            ILiquidityAaveV4Spoke(spoke).getUserSuppliedAssets(reserveId, account),
            Math.min(
                ILiquidityAaveV4Hub(hub).getAssetLiquidity(assetId),
                ILiquidityAaveV4Hub(hub).getSpokeAddedAssets(assetId, spoke)
            )
        );
    }

    /// @inheritdoc IAaveV4Liquidity
    function liquidity(address spoke, uint256 reserveId, address account, uint256 needed)
        public
        view
        returns (uint256)
    {
        if (needed == 0) return 0;
        return Math.min(needed, liquidity(spoke, reserveId, account));
    }
}
