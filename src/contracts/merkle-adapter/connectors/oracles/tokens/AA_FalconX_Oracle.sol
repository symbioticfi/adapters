// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ParetoOracle} from "../ParetoOracle.sol";

/// @title AA_FalconX_Oracle
/// @notice Mainnet AA_FalconX oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract AA_FalconX_Oracle is ParetoOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 275_519_750_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_857_276_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C;
    address private constant IDLE_CDO_ADDRESS = 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d;

    /* CONSTRUCTOR */

    constructor() ParetoOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS, IDLE_CDO_ADDRESS) {}
}
