// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title msyrupUSD_Oracle
/// @notice Mainnet msyrupUSD oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_018_452_140_000_000_000; bounds 50% / 200%.
contract msyrupUSD_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 509_226_070_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 2_036_904_280_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0x81c097e86842051B1ED4299a9E4d213Cb07f6f42;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
