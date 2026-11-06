// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mevBTC_Oracle
/// @notice Mainnet mevBTC oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_023_622_310_000_000_000; bounds 50% / 200%.
contract mevBTC_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 511_811_155_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 2_047_244_620_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0x56814399caaEDCEE4F58D2e55DA058A81DDE744f;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
