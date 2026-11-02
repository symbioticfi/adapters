// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    IHealthFactorOracle
} from "../../../../interfaces/merkle-adapter/automations/health-factors/IHealthFactorOracle.sol";
import {
    IMorphoBlueHealthFactor
} from "../../../../interfaces/merkle-adapter/automations/health-factors/IMorphoBlueHealthFactor.sol";

import {Id, IMorpho, MarketParams, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MathLib} from "morpho-blue/src/libraries/MathLib.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE} from "morpho-blue/src/libraries/ConstantsLib.sol";

/// @title MorphoBlueHealthFactor
/// @notice Contract for querying liquidation health in the Morpho Blue market.
/// @dev Adapted from MorphoBlueSnippets.userHealthFactor at 2da95cc5dd5e180b745e8c2bbc047b5d97545179.
/// See ../libraries/UPSTREAM.md for the zero-debt and invalid-market wrapper checks.
contract MorphoBlueHealthFactor is IMorphoBlueHealthFactor {
    using MathLib for uint256;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMorphoBlueHealthFactor
    function getHealthFactor(address morpho, bytes32 marketId, address account)
        public
        view
        returns (uint256 healthFactor)
    {
        if (IMorpho(morpho).market(Id.wrap(marketId)).lastUpdate == 0) revert InvalidMarket();

        Position memory position = IMorpho(morpho).position(Id.wrap(marketId), account);
        if (position.borrowShares == 0) return type(uint256).max;

        MarketParams memory params = IMorpho(morpho).idToMarketParams(Id.wrap(marketId));
        uint256 collateralPrice = IHealthFactorOracle(params.oracle).price();
        uint256 borrowed = MorphoBalancesLib.expectedBorrowAssets(IMorpho(morpho), params, account);
        uint256 maxBorrow =
            uint256(position.collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(params.lltv);
        return maxBorrow.wDivDown(borrowed);
    }
}
