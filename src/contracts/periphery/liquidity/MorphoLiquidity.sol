// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.37;

import {IBorrowCapability} from "src/interfaces/merkle_adapter/IBorrowCapability.sol";
import {IExecutorLiquidityLens} from "src/interfaces/periphery/IExecutorLiquidityLens.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

struct LiquidityMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct LiquidityMarket {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

struct LiquidityPosition {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

interface ILiquidityMorpho {
    function idToMarketParams(bytes32 id) external view returns (LiquidityMarketParams memory);
    function market(bytes32 id) external view returns (LiquidityMarket memory);
    function position(bytes32 id, address account) external view returns (LiquidityPosition memory);
}

interface ILiquidityMorphoIrm {
    function borrowRateView(LiquidityMarketParams calldata params, LiquidityMarket calldata market)
        external
        view
        returns (uint256);
}

interface ILiquidityMorphoOracle {
    function price() external view returns (uint256);
}

interface ILiquidityMorphoVault {
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
    function canSendShares(address account) external view returns (bool);
    function canReceiveAssets(address account) external view returns (bool);
}

interface ILiquidityMorphoMarketAdapter {
    function morpho() external view returns (address);
    function supplyShares(bytes32 id) external view returns (uint256);
}

interface ILiquidityMorphoVaultAdapter {
    function morphoVaultV1() external view returns (address);
}

/// @title MorphoLiquidity
/// @notice Scalar calculations for Morpho market and vault liquidity.
/// @dev Native token units, current interest and virtual shares. V2 withdrawal follows only its configured exit adapter.
abstract contract MorphoLiquidity is IExecutorLiquidityLens {
    using Math for uint256;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IExecutorLiquidityLens
    function morphoBorrow(address morpho, bytes32 marketId, address account) public view returns (uint256) {
        return _morphoBorrow(morpho, marketId, account, 1e18);
    }

    /// @inheritdoc IExecutorLiquidityLens
    function morphoBorrowCapability(address account, address morpho, bytes32 marketId, bytes32 healthFactorId)
        public
        view
        returns (uint256)
    {
        uint256 minimum = IBorrowCapability(account).minHealthFactor(healthFactorId);
        if (minimum == 0) return 0;
        return _morphoBorrow(morpho, marketId, account, Math.max(minimum, 1e18));
    }

    /// @inheritdoc IExecutorLiquidityLens
    function morphoVaultWithdraw(address vault, address account) public view returns (uint256) {
        return _morphoVaultWithdraw(vault, account, 0);
    }

    /* INTERNAL FUNCTIONS */

    function _morphoBorrow(address morpho, bytes32 marketId, address account, uint256 minimum)
        internal
        view
        returns (uint256)
    {
        LiquidityMarketParams memory params = ILiquidityMorpho(morpho).idToMarketParams(marketId);
        if (keccak256(abi.encode(params)) != marketId || params.lltv > 1e18) return 0;
        LiquidityMarket memory market = _morphoAccrued(morpho, params);
        LiquidityPosition memory position = ILiquidityMorpho(morpho).position(marketId, account);
        uint256 collateralValue = Math.mulDiv(position.collateral, ILiquidityMorphoOracle(params.oracle).price(), 1e36);
        uint256 maxDebt = Math.mulDiv(Math.mulDiv(collateralValue, params.lltv, 1e18), 1e18, minimum);
        uint256 debt = Math.mulDiv(
            position.borrowShares,
            uint256(market.totalBorrowAssets) + 1,
            uint256(market.totalBorrowShares) + 1e6,
            Math.Rounding.Ceil
        );
        uint256 amount = Math.min(maxDebt.saturatingSub(debt), _morphoCash(morpho, params, market));
        // A new borrow mints rounded-up debt shares. Search against the resulting exact rounded-up debt.
        uint256 low;
        uint256 high = amount;
        for (uint256 i; i < 128 && low < high; ++i) {
            uint256 mid = low + (high - low + 1) / 2;
            uint256 minted = Math.mulDiv(
                mid, uint256(market.totalBorrowShares) + 1e6, uint256(market.totalBorrowAssets) + 1, Math.Rounding.Ceil
            );
            uint256 finalDebt = Math.mulDiv(
                uint256(position.borrowShares) + minted,
                uint256(market.totalBorrowAssets) + mid + 1,
                uint256(market.totalBorrowShares) + minted + 1e6,
                Math.Rounding.Ceil
            );
            if (finalDebt <= maxDebt) low = mid;
            else high = mid - 1;
        }
        return low;
    }

    function _morphoVaultWithdraw(address vault, address account, uint256 depth) internal view returns (uint256) {
        if (depth >= 4) return 0;
        if (
            !ILiquidityMorphoVault(vault).canSendShares(account)
                || !ILiquidityMorphoVault(vault).canReceiveAssets(account)
        ) return 0;
        uint256 owned = IERC4626(vault).previewRedeem(IERC20(vault).balanceOf(account));
        uint256 cash = IERC20(IERC4626(vault).asset()).balanceOf(vault);
        address adapter = ILiquidityMorphoVault(vault).liquidityAdapter();
        if (adapter != address(0)) {
            cash += _morphoAdapterLiquidity(adapter, ILiquidityMorphoVault(vault).liquidityData(), depth);
        }
        return Math.min(owned, cash);
    }

    function _morphoAdapterLiquidity(address adapter, bytes memory data, uint256 depth)
        internal
        view
        returns (uint256)
    {
        try ILiquidityMorphoMarketAdapter(adapter).morpho() returns (address morpho) {
            if (data.length != 160) return 0;
            LiquidityMarketParams memory params = abi.decode(data, (LiquidityMarketParams));
            bytes32 id = keccak256(abi.encode(params));
            LiquidityMarket memory market = _morphoAccrued(morpho, params);
            uint256 ownedShares = ILiquidityMorphoMarketAdapter(adapter).supplyShares(id);
            uint256 owned = Math.mulDiv(
                ownedShares, uint256(market.totalSupplyAssets) + 1, uint256(market.totalSupplyShares) + 1e6
            );
            return Math.min(owned, _morphoCash(morpho, params, market));
        } catch {
            try ILiquidityMorphoVaultAdapter(adapter).morphoVaultV1() returns (address wrapped) {
                try ILiquidityMorphoVault(wrapped).liquidityAdapter() returns (address) {
                    return _morphoVaultWithdraw(wrapped, adapter, depth + 1);
                } catch {
                    return IERC4626(wrapped).maxWithdraw(adapter);
                }
            } catch {
                return 0;
            }
        }
    }

    function _morphoCash(address morpho, LiquidityMarketParams memory params, LiquidityMarket memory market)
        internal
        view
        returns (uint256)
    {
        return Math.min(
            uint256(market.totalSupplyAssets).saturatingSub(market.totalBorrowAssets),
            IERC20(params.loanToken).balanceOf(morpho)
        );
    }

    /// @dev Mirrors Morpho Blue's third-order interest accrual and fee share accounting.
    function _morphoAccrued(address morpho, LiquidityMarketParams memory params)
        internal
        view
        returns (LiquidityMarket memory market)
    {
        market = ILiquidityMorpho(morpho).market(keccak256(abi.encode(params)));
        uint256 elapsed = block.timestamp - market.lastUpdate;
        if (elapsed == 0 || market.totalBorrowAssets == 0 || params.irm == address(0)) return market;
        uint256 rateTime = ILiquidityMorphoIrm(params.irm).borrowRateView(params, market) * elapsed;
        uint256 second = Math.mulDiv(rateTime, rateTime, 2e18);
        uint256 third = Math.mulDiv(second, rateTime, 3e18);
        uint256 interest = Math.mulDiv(market.totalBorrowAssets, rateTime + second + third, 1e18);
        uint256 borrowed = uint256(market.totalBorrowAssets) + interest;
        uint256 supplied = uint256(market.totalSupplyAssets) + interest;
        uint256 shares = market.totalSupplyShares;
        if (market.fee > 0) {
            uint256 fee = Math.mulDiv(interest, market.fee, 1e18);
            shares += Math.mulDiv(fee, shares + 1e6, supplied - fee + 1);
        }
        if (borrowed > type(uint128).max || supplied > type(uint128).max || shares > type(uint128).max) revert();
        market.totalBorrowAssets = uint128(borrowed);
        market.totalSupplyAssets = uint128(supplied);
        market.totalSupplyShares = uint128(shares);
    }
}
