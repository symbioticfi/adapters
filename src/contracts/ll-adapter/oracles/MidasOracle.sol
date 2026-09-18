// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {Oracle} from "./Oracle.sol";

import {IMidasDataFeed, IMidasOracle} from "../../../interfaces/ll-adapter/midas/IMidasOracle.sol";

/// @title MidasOracle
/// @notice Midas oracle contract returning a token price in `1e18` precision.
contract MidasOracle is Oracle, IMidasOracle {
    /* IMMUTABLES */

    /// @inheritdoc IMidasOracle
    address public immutable DATA_FEED;

    /* CONSTRUCTOR */

    /// @notice Creates the Midas data-feed oracle.
    constructor(uint256 newMinPrice, uint256 newMaxPrice, address newDataFeed) Oracle(newMinPrice, newMaxPrice) {
        DATA_FEED = newDataFeed;
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        return IMidasDataFeed(DATA_FEED).getDataInBase18();
    }
}
