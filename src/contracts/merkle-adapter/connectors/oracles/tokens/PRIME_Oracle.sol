// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {FigureOracle} from "../FigureOracle.sol";

/// @title PRIME_Oracle
/// @notice Mainnet PRIME oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract PRIME_Oracle is FigureOracle {
    /* CONSTRUCTOR */

    constructor()
        FigureOracle(262_415_750_000_000_000, 3_673_820_500_000_000_000, 0x19ebb35279A16207Ec4ba82799CC64715065F7F6)
    {}
}
