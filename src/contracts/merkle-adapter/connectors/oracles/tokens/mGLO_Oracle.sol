// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mGLO_Oracle
/// @notice Mainnet mGLO oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract mGLO_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(251_441_200_000_000_000, 3_520_176_800_000_000_000, 0x21a790C7fa8bfE7a56E5612Af6A20de10554eD73)
    {}
}
