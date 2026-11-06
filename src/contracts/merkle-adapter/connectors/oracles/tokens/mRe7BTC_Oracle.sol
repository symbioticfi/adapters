// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mRe7BTC_Oracle
/// @notice Mainnet mRe7BTC oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 996_788_770_000_000_000; bounds 50% / 200%.
contract mRe7BTC_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 498_394_385_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 1_993_577_540_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0xB5D6483c556Bc6810b55B983315016Fcb374186D;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
