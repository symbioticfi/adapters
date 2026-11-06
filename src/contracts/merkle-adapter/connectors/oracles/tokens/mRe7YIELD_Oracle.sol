// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mRe7YIELD_Oracle
/// @notice Mainnet mRe7YIELD oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_083_514_070_000_000_000; bounds 25% / 350%.
contract mRe7YIELD_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(270_878_517_500_000_000, 3_792_299_245_000_000_000, 0x7E8C632ab231479886AF1Bc02B9D646e4634Da93)
    {}
}
