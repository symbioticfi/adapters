// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title CarryTradeUSDTRYLeverage_Oracle
/// @notice Mainnet CarryTradeUSDTRYLeverage oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract CarryTradeUSDTRYLeverage_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(261_000_000_000_000_000, 3_653_400_000_000_000_000, 0xE65F08D9D0b010965d69253769A33511b72d8E79)
    {}
}
