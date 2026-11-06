// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mFONE_Oracle
/// @notice Mainnet mFONE oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract mFONE_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 275_900_000_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_862_200_000_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0xCF4e49f5e750Af8F2f9Aa1642B68E5839D9c1C00;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
