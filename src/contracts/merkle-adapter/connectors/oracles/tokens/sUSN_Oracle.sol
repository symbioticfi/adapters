// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {NoonOracle} from "../NoonOracle.sol";

/// @title sUSN_Oracle
/// @notice Mainnet sUSN oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_234_780_000_000_000_000; bounds 50% / 250%.
contract sUSN_Oracle is NoonOracle {
    /* CONSTRUCTOR */

    constructor()
        NoonOracle(
            617_390_000_000_000_000,
            3_086_950_000_000_000_000,
            0xE24a3DC889621612422A64E6388927901608B91D,
            0x9F8D0a683871125083170F65430F8A15aFfa0086,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        )
    {}
}
