// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IBorrowCapability} from "src/interfaces/merkle-adapter/capabilities/IBorrowCapability.sol";
import {IExecutorLiquidityLens} from "src/interfaces/periphery/IExecutorLiquidityLens.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IOracle as IMorphoOracle} from "morpho-blue/src/interfaces/IOracle.sol";
import {Id, IMorpho, MarketParams, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "morpho-blue/src/libraries/SharesMathLib.sol";

struct MarketBalances {
    uint256 totalSupplyAssets;
    uint256 totalSupplyShares;
    uint256 totalBorrowAssets;
    uint256 totalBorrowShares;
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
    using SharesMathLib for uint256;

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
        MarketParams memory params = IMorpho(morpho).idToMarketParams(Id.wrap(marketId));
        if (keccak256(abi.encode(params)) != marketId || params.lltv > 1e18) return 0;
        MarketBalances memory market = _morphoAccrued(morpho, params);
        Position memory position = IMorpho(morpho).position(Id.wrap(marketId), account);
        uint256 collateralValue = Math.mulDiv(position.collateral, IMorphoOracle(params.oracle).price(), 1e36);
        uint256 maxDebt = Math.mulDiv(Math.mulDiv(collateralValue, params.lltv, 1e18), 1e18, minimum);
        uint256 debt = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 amount = Math.min(maxDebt.saturatingSub(debt), _morphoCash(morpho, params, market));
        // A new borrow mints rounded-up debt shares. Search against the resulting exact rounded-up debt.
        uint256 low;
        uint256 high = amount;
        for (uint256 i; i < 128 && low < high; ++i) {
            uint256 mid = low + (high - low + 1) / 2;
            uint256 minted = mid.toSharesUp(market.totalBorrowAssets, market.totalBorrowShares);
            uint256 finalDebt = (uint256(position.borrowShares) + minted)
            .toAssetsUp(market.totalBorrowAssets + mid, market.totalBorrowShares + minted);
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
            MarketParams memory params = abi.decode(data, (MarketParams));
            bytes32 id = keccak256(abi.encode(params));
            MarketBalances memory market = _morphoAccrued(morpho, params);
            uint256 ownedShares = ILiquidityMorphoMarketAdapter(adapter).supplyShares(id);
            uint256 owned = ownedShares.toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);
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

    function _morphoCash(address morpho, MarketParams memory params, MarketBalances memory market)
        internal
        view
        returns (uint256)
    {
        return Math.min(
            uint256(market.totalSupplyAssets).saturatingSub(market.totalBorrowAssets),
            IERC20(params.loanToken).balanceOf(morpho)
        );
    }

    /// @dev Uses the pinned Morpho Blue periphery for interest accrual and fee shares.
    function _morphoAccrued(address morpho, MarketParams memory params)
        internal
        view
        returns (MarketBalances memory market)
    {
        (market.totalSupplyAssets, market.totalSupplyShares, market.totalBorrowAssets, market.totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(morpho), params);
    }
}
