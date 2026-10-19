// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
// Modifications Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    IHealthFactorOracle
} from "../../../../interfaces/merkle-adapter/automations/health-factors/IHealthFactorOracle.sol";
import {
    IMorphoMidnightHealthFactor
} from "../../../../interfaces/merkle-adapter/automations/health-factors/IMorphoMidnightHealthFactor.sol";
import {IMorphoMidnight} from "../../../../interfaces/merkle-adapter/automations/health-factors/IMorphoMidnight.sol";

import {ORACLE_PRICE_SCALE, WAD} from "morpho-midnight/src/libraries/ConstantsLib.sol";
import {UtilsLib} from "morpho-midnight/src/libraries/UtilsLib.sol";

/// @title MorphoMidnightHealthFactor
/// @notice Contract for querying liquidation health in the Morpho Midnight market.
/// @dev Adapted from Midnight.isHealthy at 531ab3b23f95dcc660b8805e46f089248c6b994e; see ../libraries/UPSTREAM.md.
contract MorphoMidnightHealthFactor is IMorphoMidnightHealthFactor {
    using UtilsLib for uint256;
    using UtilsLib for uint128;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMorphoMidnightHealthFactor
    function getHealthFactor(address midnight, bytes32 marketId, address account)
        public
        view
        returns (uint256 healthFactor)
    {
        IMorphoMidnight.Market memory market = IMorphoMidnight(midnight).toMarket(marketId);
        uint256 debt = IMorphoMidnight(midnight).debt(marketId, account);
        if (debt == 0) return type(uint256).max;

        if (block.timestamp > market.maturity) return 0;

        uint128 collateralBitmap = IMorphoMidnight(midnight).collateralBitmap(marketId, account);
        uint256 maxDebt;
        while (collateralBitmap > 0) {
            uint256 i = UtilsLib.msb(collateralBitmap);
            uint256 collateral = IMorphoMidnight(midnight).collateral(marketId, account, i);
            IMorphoMidnight.CollateralParams memory collateralParam = market.collateralParams[i];
            uint256 price = IHealthFactorOracle(collateralParam.oracle).price();
            maxDebt += collateral.mulDivDown(price, ORACLE_PRICE_SCALE).mulDivDown(collateralParam.lltv, WAD);
            collateralBitmap = collateralBitmap.clearBit(i);
        }
        return maxDebt.mulDivDown(WAD, debt);
    }
}
