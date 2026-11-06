// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ParetoOracle} from "../ParetoOracle.sol";

/// @title AA_FalconX_Oracle
/// @notice Mainnet AA_FalconX oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract AA_FalconX_Oracle is ParetoOracle {
    /* CONSTRUCTOR */

    constructor()
        ParetoOracle(
            275_519_750_000_000_000,
            3_857_276_500_000_000_000,
            0xC26A6Fa2C37b38E549a4a1807543801Db684f99C,
            0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d
        )
    {}
}
