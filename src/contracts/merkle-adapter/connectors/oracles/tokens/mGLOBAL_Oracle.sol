// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mGLOBAL_Oracle
/// @notice Mainnet mGLOBAL oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract mGLOBAL_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(251_441_200_000_000_000, 3_520_176_800_000_000_000, 0x517cf115e750d02aeB978011fCE05691613d7ed7)
    {}
}
