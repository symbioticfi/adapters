// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mHYPER_Oracle
/// @notice Mainnet mHYPER oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract mHYPER_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(277_200_000_000_000_000, 3_880_300_000_000_000_000, 0x92004DCC5359eD67f287F32d12715A37916deCdE)
    {}
}
