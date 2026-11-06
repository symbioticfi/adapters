// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mROX_Oracle
/// @notice Mainnet mROX oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract mROX_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(282_900_000_000_000_000, 3_961_200_000_000_000_000, 0x2c7d47c56015be6aa8442Da78796a965928E7c4e)
    {}
}
