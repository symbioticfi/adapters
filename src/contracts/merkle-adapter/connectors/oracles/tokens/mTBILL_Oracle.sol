// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mTBILL_Oracle
/// @notice Mainnet mTBILL oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_077_368_760_000_000_000; bounds 25% / 350%.
contract mTBILL_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 269_342_190_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_770_790_660_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0xfCEE9754E8C375e145303b7cE7BEca3201734A2B;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
