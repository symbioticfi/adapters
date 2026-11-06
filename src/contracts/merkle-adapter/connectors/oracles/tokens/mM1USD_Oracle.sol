// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mM1USD_Oracle
/// @notice Mainnet mM1USD oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract mM1USD_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(253_500_000_000_000_000, 3_548_800_000_000_000_000, 0xF1aBD1a4Fc5fa2848Cf3763FBE7B0DF366da9279)
    {}
}
