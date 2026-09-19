// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {VaultV2LiquidityLib} from "../libraries/VaultV2LiquidityLib.sol";

import {IExecutorLiquidityLens} from "src/interfaces/merkle-adapter/automations/IExecutorLiquidityLens.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IOracle as IMorphoOracle} from "morpho-blue/src/interfaces/IOracle.sol";
import {Id, IMorpho, MarketParams, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MathLib} from "morpho-blue/src/libraries/MathLib.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE} from "morpho-blue/src/libraries/ConstantsLib.sol";
import {SharesMathLib} from "morpho-blue/src/libraries/SharesMathLib.sol";

/// @title MorphoLiquidity
/// @notice Scalar calculations for Morpho market and vault liquidity.
/// @dev Native token units, current interest and virtual shares. V2 withdrawal follows only its configured exit adapter.
abstract contract MorphoLiquidity is IExecutorLiquidityLens {
    using Math for uint256;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    struct BorrowMarket {
        uint256 totalSupplyAssets;
        uint256 totalBorrowAssets;
        uint256 totalBorrowShares;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IExecutorLiquidityLens
    function morphoBorrow(address morpho, bytes32 marketId, address account) public view returns (uint256) {
        return _morphoBorrow(morpho, marketId, account, 1e18);
    }

    /// @inheritdoc IExecutorLiquidityLens
    function morphoBorrowGuarded(address morpho, bytes32 marketId, address account, uint256 minHealthFactor)
        public
        view
        returns (uint256)
    {
        return _morphoBorrow(morpho, marketId, account, Math.max(minHealthFactor, 1e18));
    }

    /// @inheritdoc IExecutorLiquidityLens
    function morphoVaultWithdraw(address vault, address account) public view returns (uint256) {
        return VaultV2LiquidityLib.maxWithdrawView(vault, account, 0);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev BlueSnippets' collateral limit, then Morpho.borrow/_isHealthy share accounting.
    /// Only the search for an amount and the requested health floor are integration logic; see ../libraries/UPSTREAM.md.
    function _morphoBorrow(address morpho, bytes32 marketId, address account, uint256 minimum)
        internal
        view
        returns (uint256)
    {
        BorrowMarket memory market;
        Position memory position;
        uint256 maxDebt;
        uint256 high;
        {
            MarketParams memory params = IMorpho(morpho).idToMarketParams(Id.wrap(marketId));
            if (keccak256(abi.encode(params)) != marketId || params.lltv > 1e18) return 0;
            (market.totalSupplyAssets,, market.totalBorrowAssets, market.totalBorrowShares) =
                MorphoBalancesLib.expectedMarketBalances(IMorpho(morpho), params);
            high = Math.min(
                market.totalSupplyAssets.saturatingSub(market.totalBorrowAssets),
                IERC20(params.loanToken).balanceOf(morpho)
            );
            position = IMorpho(morpho).position(Id.wrap(marketId), account);
            uint256 collateralPrice = IMorphoOracle(params.oracle).price();
            maxDebt = uint256(position.collateral)
                .mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
                .wMulDown(params.lltv)
                .wDivDown(minimum);
        }
        // A new borrow mints rounded-up debt shares. Search against the resulting exact rounded-up debt.
        uint256 low;
        high = Math.min(
            high,
            maxDebt.saturatingSub(
                uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares)
            )
        );
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
}
