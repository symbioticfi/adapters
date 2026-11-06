// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mAPOLLO_Oracle
/// @notice Mainnet mAPOLLO oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_129_948_930_000_000_000; bounds 25% / 350%.
contract mAPOLLO_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 282_487_232_500_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_954_821_255_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0x9aEBf5d6F9411BAc355021ddFbe9B2c756BDD358;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
