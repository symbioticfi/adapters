// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {OpenEdenOracle} from "../OpenEdenOracle.sol";

/// @title HYBOND_Oracle
/// @notice Mainnet HYBOND oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_734_062_000_000_000_000; bounds 25% / 350%.
contract HYBOND_Oracle is OpenEdenOracle {
    /* CONSTRUCTOR */

    constructor()
        OpenEdenOracle(
            433_515_500_000_000_000,
            6_069_217_000_000_000_000,
            0x1204371AC0e5176f4B8c5B2F16C2Bec551b6FC1a,
            0xD84C2571E05a59108Ead1c600D16133f0710E569
        )
    {}
}
