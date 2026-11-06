// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mMEV_Oracle
/// @notice Mainnet mMEV oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_159_368_190_000_000_000; bounds 25% / 350%.
contract mMEV_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 289_842_047_500_000_000;
    uint256 private constant MAX_PRICE_BOUND = 4_057_788_665_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0x9BF00b7CFC00D6A7a2e2C994DB8c8dCa467ee359;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
