// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Oracle} from "./Oracle.sol";

import {IAssetoOracle} from "../../../interfaces/ll-adapter/oracles/IAssetoOracle.sol";
import {IAssetoPricer} from "../../../interfaces/ll-adapter/asseto/IAssetoPricer.sol";
import {IPriceDataOracle} from "../../../interfaces/ll-adapter/IPriceDataOracle.sol";

/// @title AssetoOracle
/// @notice Asseto oracle contract returning token NAV in `1e18` precision.
contract AssetoOracle is Oracle, IAssetoOracle {
    /* IMMUTABLES */

    /// @inheritdoc IAssetoOracle
    address public immutable PRICER;

    /* CONSTRUCTOR */

    /// @notice Creates the Asseto pricer-backed oracle.
    constructor(uint256 newMinPrice, uint256 newMaxPrice, address newPricer) Oracle(newMinPrice, newMaxPrice) {
        PRICER = newPricer;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IPriceDataOracle
    function getPriceData() public view returns (uint256 price, uint48 updatedAt) {
        uint256 timestamp;
        price = getPrice();
        (, timestamp) = IAssetoPricer(PRICER).prices(IAssetoPricer(PRICER).latestPriceId());
        updatedAt = uint48(timestamp);
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        return IAssetoPricer(PRICER).getLatestPrice();
    }
}
