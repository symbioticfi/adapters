// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title StockMarketTRBasisTrade_Oracle
/// @notice Mainnet StockMarketTRBasisTrade oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract StockMarketTRBasisTrade_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(253_000_000_000_000_000, 3_541_400_000_000_000_000, 0xCF79a4ae663117238aB6DD9d0FCca942Be5d1644)
    {}
}
