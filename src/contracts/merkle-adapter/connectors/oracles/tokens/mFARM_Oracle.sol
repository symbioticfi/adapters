// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mFARM_Oracle
/// @notice Mainnet mFARM oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_012_604_620_000_000_000; bounds 50% / 200%.
contract mFARM_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 506_302_310_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 2_025_209_240_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0x9f49B0980B141b539e2A94Ec0864Faf699fF9524;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
