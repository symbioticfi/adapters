// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title msyrupUSDp_Oracle
/// @notice Mainnet msyrupUSDp oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_061_272_690_000_000_000; bounds 25% / 350%.
contract msyrupUSDp_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(265_318_172_500_000_000, 3_714_454_415_000_000_000, 0x7833397dA276d6B588e76466C14c82b2d733Cfb6)
    {}
}
