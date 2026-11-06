// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mEVUSD_Oracle
/// @notice Mainnet mEVUSD oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_045_378_070_000_000_000; bounds 50% / 200%.
contract mEVUSD_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 522_689_035_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 2_090_756_140_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0x508Fe9556C7919E64406bB4042760d7Bb1F40fC9;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
