// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ParetoOracle} from "../ParetoOracle.sol";

/// @title AA_AdaptiveFrontier_Oracle
/// @notice Mainnet AA_AdaptiveFrontier oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_120_872_000_000_000_000; bounds 25% / 350%.
contract AA_AdaptiveFrontier_Oracle is ParetoOracle {
    /* CONSTRUCTOR */

    constructor()
        ParetoOracle(
            280_218_000_000_000_000,
            3_923_052_000_000_000_000,
            0xae7913c672c7F1f76C2a1a0Ac4de97d082681234,
            0x14B8E918848349D1e71e806a52c13D4e0d3246E0
        )
    {}
}
