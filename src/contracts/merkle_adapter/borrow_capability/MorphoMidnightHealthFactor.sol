// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IHealthFactorOracle} from "../../../interfaces/merkle_adapter/borrow_capability/IHealthFactorOracle.sol";
import {
    IMorphoMidnightHealthFactor
} from "../../../interfaces/merkle_adapter/borrow_capability/IMorphoMidnightHealthFactor.sol";
import {IMorphoMidnight} from "../../../interfaces/merkle_adapter/borrow_capability/IMorphoMidnight.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {UtilsLib} from "morpho-midnight/src/libraries/UtilsLib.sol";

/// @title MorphoMidnightHealthFactor
/// @notice Contract for querying liquidation health in the Morpho Midnight market.
contract MorphoMidnightHealthFactor is IMorphoMidnightHealthFactor {
    using Math for uint256;

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
        uint256 capacity;
        while (collateralBitmap != 0) {
            uint256 i = UtilsLib.msb(collateralBitmap);
            capacity += uint256(IMorphoMidnight(midnight).collateral(marketId, account, i))
                .mulDiv(IHealthFactorOracle(market.collateralParams[i].oracle).price(), 1e36)
                .mulDiv(market.collateralParams[i].lltv, 1e18);
            // The highest set bit of a nonzero uint128 is always below 128.
            collateralBitmap ^= uint128(1) << i;
        }
        return capacity.mulDiv(1e18, debt);
    }
}
