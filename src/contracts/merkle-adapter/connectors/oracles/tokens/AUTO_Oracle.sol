// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {FigureOracle} from "../FigureOracle.sol";

/// @title AUTO_Oracle
/// @notice Mainnet AUTO oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_031_312_000_000_000_000; bounds 25% / 350%.
contract AUTO_Oracle is FigureOracle {
    /* CONSTRUCTOR */

    constructor()
        FigureOracle(257_828_000_000_000_000, 3_609_592_000_000_000_000, 0x997E2Efbce91D170B00EA402e35a66C887EE1da9)
    {}
}
