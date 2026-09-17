// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {IHealthFactorOracle} from "../../../interfaces/merkle_adapter/borrow_capability/IHealthFactorOracle.sol";
import {IMorphoBlue, IMorphoBlueIrm} from "../../../interfaces/merkle_adapter/borrow_capability/IMorphoBlue.sol";
import {
    IMorphoBlueHealthFactor
} from "../../../interfaces/merkle_adapter/borrow_capability/IMorphoBlueHealthFactor.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MorphoBlueHealthFactor
/// @notice Contract for querying liquidation health in the Morpho Blue market.
contract MorphoBlueHealthFactor is IMorphoBlueHealthFactor {
    using Math for uint256;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMorphoBlueHealthFactor
    function getHealthFactor(address morpho, bytes32 marketId, address account)
        public
        view
        returns (uint256 healthFactor)
    {
        IMorphoBlue.Market memory market = IMorphoBlue(morpho).market(marketId);
        if (market.lastUpdate == 0) revert InvalidMarket();

        IMorphoBlue.Position memory position = IMorphoBlue(morpho).position(marketId, account);
        if (position.borrowShares == 0) return type(uint256).max;

        IMorphoBlue.MarketParams memory params = IMorphoBlue(morpho).idToMarketParams(marketId);
        uint256 borrowAssets = market.totalBorrowAssets;
        if (block.timestamp > market.lastUpdate && borrowAssets != 0 && params.irm != address(0)) {
            // Match Morpho's third-order interest approximation without mutating the market.
            uint256 first =
                IMorphoBlueIrm(params.irm).borrowRateView(params, market) * (block.timestamp - market.lastUpdate);
            uint256 second = first.mulDiv(first, 2e18);
            borrowAssets += borrowAssets.mulDiv(first + second + second.mulDiv(first, 3e18), 1e18);
        }

        // Morpho adds one virtual asset and 1e6 virtual shares; debt rounds up.
        return uint256(position.collateral)
            .mulDiv(IHealthFactorOracle(params.oracle).price(), 1e36)
            .mulDiv(params.lltv, 1e18)
            .mulDiv(
                1e18,
                uint256(position.borrowShares)
                    .mulDiv(borrowAssets + 1, uint256(market.totalBorrowShares) + 1e6, Math.Rounding.Ceil)
            );
    }
}
