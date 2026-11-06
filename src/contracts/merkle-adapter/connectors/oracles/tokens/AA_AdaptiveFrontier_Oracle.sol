// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ParetoOracle} from "../ParetoOracle.sol";

/// @title AA_AdaptiveFrontier_Oracle
/// @notice Mainnet AA_AdaptiveFrontier oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_120_872_000_000_000_000; bounds 25% / 350%.
contract AA_AdaptiveFrontier_Oracle is ParetoOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 280_218_000_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_923_052_000_000_000_000;
    address private constant TOKEN_ADDRESS = 0xae7913c672c7F1f76C2a1a0Ac4de97d082681234;
    address private constant IDLE_CDO_ADDRESS = 0x14B8E918848349D1e71e806a52c13D4e0d3246E0;

    /* CONSTRUCTOR */

    constructor() ParetoOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS, IDLE_CDO_ADDRESS) {}
}
