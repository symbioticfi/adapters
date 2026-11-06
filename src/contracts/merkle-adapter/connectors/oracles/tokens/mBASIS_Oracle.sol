// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mBASIS_Oracle
/// @notice Mainnet mBASIS oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_224_003_820_000_000_000; bounds 25% / 350%.
contract mBASIS_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(306_000_955_000_000_000, 4_284_013_370_000_000_000, 0x1615cBC603192ae8A9FF20E98dd0e40a405d76e4)
    {}
}
