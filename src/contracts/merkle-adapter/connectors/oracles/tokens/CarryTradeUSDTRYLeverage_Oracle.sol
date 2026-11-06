// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title CarryTradeUSDTRYLeverage_Oracle
/// @notice Mainnet CarryTradeUSDTRYLeverage oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract CarryTradeUSDTRYLeverage_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 261_000_000_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_653_400_000_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0xE65F08D9D0b010965d69253769A33511b72d8E79;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
