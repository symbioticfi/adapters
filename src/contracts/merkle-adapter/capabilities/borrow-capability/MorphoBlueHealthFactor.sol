// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    IHealthFactorOracle
} from "../../../../interfaces/merkle-adapter/capabilities/borrow-capability/IHealthFactorOracle.sol";
import {
    IMorphoBlueHealthFactor
} from "../../../../interfaces/merkle-adapter/capabilities/borrow-capability/IMorphoBlueHealthFactor.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Id, IMorpho, MarketParams, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

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
        if (IMorpho(morpho).market(Id.wrap(marketId)).lastUpdate == 0) revert InvalidMarket();

        Position memory position = IMorpho(morpho).position(Id.wrap(marketId), account);
        if (position.borrowShares == 0) return type(uint256).max;

        MarketParams memory params = IMorpho(morpho).idToMarketParams(Id.wrap(marketId));
        return uint256(position.collateral)
            .mulDiv(IHealthFactorOracle(params.oracle).price(), 1e36)
            .mulDiv(params.lltv, 1e18)
            .mulDiv(1e18, MorphoBalancesLib.expectedBorrowAssets(IMorpho(morpho), params, account));
    }
}
