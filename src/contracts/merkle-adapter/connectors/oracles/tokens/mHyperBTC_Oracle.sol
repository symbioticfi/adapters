// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mHyperBTC_Oracle
/// @notice Mainnet mHyperBTC oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_029_160_020_000_000_000; bounds 50% / 200%.
contract mHyperBTC_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(514_580_010_000_000_000, 2_058_320_040_000_000_000, 0xb75B82b2012138815d1A2c4aB5B8b987da043157)
    {}
}
