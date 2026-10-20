// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {PercentageMath} from "./PercentageMath.sol";

import {
    AAVE_BORROWING_MASK,
    IAaveV3Liquidity
} from "../../../../interfaces/merkle-adapter/automations/liquidity/IAaveV3Liquidity.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ILiquidityAavePool {
    function getConfiguration(address asset) external view returns (uint256);
    function getUserConfiguration(address account) external view returns (uint256);
    function getUserEMode(address account) external view returns (uint256);
    function getReserveAddressById(uint16 id) external view returns (address);
    function getReserveAToken(address asset) external view returns (address);
    function getVirtualUnderlyingBalance(address asset) external view returns (uint128);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
    function ADDRESSES_PROVIDER() external view returns (address);
    function getUserAccountData(address account)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256);
}

interface ILiquidityAaveProvider {
    function getPriceOracle() external view returns (address);
}

interface ILiquidityAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

/// @title AaveV3Liquidity
/// @notice Scalar calculations for Aave V3 withdrawal liquidity.
/// @dev Aave V3.3+ reserve queries. The debt-aware query supports standard-mode accounts only.
/// Stateless and permissionless: the query returns underlying token units for the explicitly
/// encoded account, never msg.sender. Failed reads revert and cannot authorize any funding call.
/// RecipeExecutor still enforces the actual balance delta, current Merkle proof and role on every
/// used source. Deploy through ImmutableFactory(type(AaveV3Liquidity).creationCode).create("").
/// @custom:security-contact https://github.com/symbioticfi/adapters/security
contract AaveV3Liquidity is IAaveV3Liquidity {
    using Math for uint256;
    using PercentageMath for uint256;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IAaveV3Liquidity
    function liquidity(address pool, address asset, address account) public view returns (uint256) {
        return Math.min(
            IERC20(ILiquidityAavePool(pool).getReserveAToken(asset)).balanceOf(account),
            ILiquidityAavePool(pool).getVirtualUnderlyingBalance(asset)
        );
    }

    /// @inheritdoc IAaveV3Liquidity
    function liquidityWithBorrow(address pool, address asset, address account) public view returns (uint256 amount) {
        if (ILiquidityAavePool(pool).getUserEMode(account) > 0) return 0;
        AaveReserve memory r;
        r.configuration = ILiquidityAavePool(pool).getConfiguration(asset);
        if (!_aaveActive(r.configuration)) return 0;
        r.aToken = ILiquidityAavePool(pool).getReserveAToken(asset);
        r.cash =
            Math.min(IERC20(asset).balanceOf(r.aToken), ILiquidityAavePool(pool).getVirtualUnderlyingBalance(asset));
        amount = Math.min(IERC20(r.aToken).balanceOf(account), r.cash);
        if (amount == 0) return 0;
        uint256 user = ILiquidityAavePool(pool).getUserConfiguration(account);
        // Aave records every borrowed reserve in the even bits of the user configuration.
        if (user & AAVE_BORROWING_MASK == 0) return amount;
        (uint256 collateral, uint256 debt,, uint256 threshold,, uint256 health) =
            ILiquidityAavePool(pool).getUserAccountData(account);
        if (debt == 0) return amount;
        if (health < 1e18) return 0;
        (bool used, bool restricted) = _aaveUserFlags(pool, asset, user, r.configuration);
        if (restricted) return 0;
        if (!used) return amount;
        uint256 reserveThreshold = (r.configuration >> 16) & 0xffff;
        if (reserveThreshold == 0) return 0;
        r.price = ILiquidityAaveOracle(
                ILiquidityAaveProvider(ILiquidityAavePool(pool).ADDRESSES_PROVIDER()).getPriceOracle()
            )
            .getAssetPrice(asset);
        if (r.price == 0) return 0;
        uint256 decimals = (r.configuration >> 48) & 0xff;
        if (decimals > 36) revert();
        r.unit = 10 ** decimals;
        r.incomeRounding = 2 * Math.ceilDiv(ILiquidityAavePool(pool).getReserveNormalizedIncome(asset), 1e27);
        uint256 weighted = collateral.percentMulFloor(threshold);
        // V3.3/V3.4 truncate the post-withdraw weighted threshold to whole basis points.
        // Reserve one basis point of collateral plus two base units for the remaining conversion rounding.
        uint256 spare = weighted.saturatingSub(debt).saturatingSub(Math.ceilDiv(collateral, 10_000) + 2);
        uint256 capacity = spare.percentDivFloor(reserveThreshold).mulDiv(r.unit, r.price);
        return Math.min(amount, capacity.saturatingSub(r.incomeRounding));
    }

    /* INTERNAL FUNCTIONS */

    function _aaveActive(uint256 configuration) internal pure returns (bool) {
        return configuration & (1 << 56) > 0 && configuration & (1 << 60) == 0;
    }

    function _aaveUserFlags(address pool, address asset, uint256 user, uint256 assetConfiguration)
        internal
        view
        returns (bool used, bool restricted)
    {
        for (uint16 i; user > 0 && i < 128; ++i) {
            uint256 flags = user & 3;
            user >>= 2;
            if (flags == 0) continue;
            address reserve = ILiquidityAavePool(pool).getReserveAddressById(i);
            uint256 configuration =
                reserve == asset ? assetConfiguration : ILiquidityAavePool(pool).getConfiguration(reserve);
            if (flags & 2 > 0) {
                if (reserve == asset) used = true;
                // Isolation and zero-LTV collateral need protocol-specific unwind ordering.
                if (configuration >> 212 & ((1 << 40) - 1) > 0 || configuration & 0xffff == 0) restricted = true;
            }
            if (flags & 1 > 0 && configuration & (1 << 62) > 0) restricted = true;
        }
        if (assetConfiguration & (1 << 62) > 0) restricted = true;
    }
}
