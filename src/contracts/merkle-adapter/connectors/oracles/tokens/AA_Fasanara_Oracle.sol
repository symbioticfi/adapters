// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ParetoOracle} from "../ParetoOracle.sol";

/// @title AA_Fasanara_Oracle
/// @notice Mainnet AA_Fasanara oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_196_323_000_000_000_000; bounds 25% / 350%.
contract AA_Fasanara_Oracle is ParetoOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 299_080_750_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 4_187_130_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0x45054c6753b4Bce40C5d54418DabC20b070F85bE;
    address private constant IDLE_CDO_ADDRESS = 0xf6223C567F21E33e859ED7A045773526E9E3c2D5;

    /* CONSTRUCTOR */

    constructor() ParetoOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS, IDLE_CDO_ADDRESS) {}
}
