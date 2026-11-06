// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mBTC_Oracle
/// @notice Mainnet mBTC oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_032_403_130_000_000_000; bounds 50% / 200%.
contract mBTC_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 516_201_565_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 2_064_806_260_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0x9987BE0c1dc5Cd284a4D766f4B5feB4F3cb3E28e;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
