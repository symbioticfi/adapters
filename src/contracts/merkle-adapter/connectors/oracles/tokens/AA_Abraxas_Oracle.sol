// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ParetoOracle} from "../ParetoOracle.sol";

/// @title AA_Abraxas_Oracle
/// @notice Mainnet AA_Abraxas oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_078_587_000_000_000_000; bounds 25% / 350%.
contract AA_Abraxas_Oracle is ParetoOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 269_646_750_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_775_054_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0x6dbDEeF7a188bEaFFC2c57006e5D8edAf0C0e9e6;
    address private constant IDLE_CDO_ADDRESS = 0x0Ad21c3Ac4ffE7C1Ed2b1B717cd051DeD365fa32;

    /* CONSTRUCTOR */

    constructor() ParetoOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS, IDLE_CDO_ADDRESS) {}
}
