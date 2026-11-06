// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mEDGE_Oracle
/// @notice Mainnet mEDGE oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_154_018_820_000_000_000; bounds 25% / 350%.
contract mEDGE_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(288_504_705_000_000_000, 4_039_065_870_000_000_000, 0x20cd58F72cF1727a2937eB1816593390cf8d91cB)
    {}
}
