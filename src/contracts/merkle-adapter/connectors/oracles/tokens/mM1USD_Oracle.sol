// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mM1USD_Oracle
/// @notice Mainnet mM1USD oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract mM1USD_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 253_500_000_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_548_800_000_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0xF1aBD1a4Fc5fa2848Cf3763FBE7B0DF366da9279;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
