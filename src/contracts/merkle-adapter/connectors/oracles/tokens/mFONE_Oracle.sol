// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mFONE_Oracle
/// @notice Mainnet mFONE oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract mFONE_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(275_900_000_000_000_000, 3_862_200_000_000_000_000, 0xCF4e49f5e750Af8F2f9Aa1642B68E5839D9c1C00)
    {}
}
