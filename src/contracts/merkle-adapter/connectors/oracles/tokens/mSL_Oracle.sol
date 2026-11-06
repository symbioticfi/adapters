// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mSL_Oracle
/// @notice Mainnet mSL oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_169_149_670_000_000_000; bounds 50% / 200%.
contract mSL_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 584_574_835_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 2_338_299_340_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0xbdc0304210972be75Fd2247838BFF2b64474f15c;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
