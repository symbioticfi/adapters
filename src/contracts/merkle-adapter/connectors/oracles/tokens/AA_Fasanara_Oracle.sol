// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ParetoOracle} from "../ParetoOracle.sol";

/// @title AA_Fasanara_Oracle
/// @notice Mainnet AA_Fasanara oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_196_323_000_000_000_000; bounds 25% / 350%.
contract AA_Fasanara_Oracle is ParetoOracle {
    /* CONSTRUCTOR */

    constructor()
        ParetoOracle(
            299_080_750_000_000_000,
            4_187_130_500_000_000_000,
            0x45054c6753b4Bce40C5d54418DabC20b070F85bE,
            0xf6223C567F21E33e859ED7A045773526E9E3c2D5
        )
    {}
}
