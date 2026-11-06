// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mGLO_Oracle
/// @notice Mainnet mGLO oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract mGLO_Oracle is MidasOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 251_441_200_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_520_176_800_000_000_000;
    address private constant DATA_FEED_ADDRESS = 0x21a790C7fa8bfE7a56E5612Af6A20de10554eD73;

    /* CONSTRUCTOR */

    constructor() MidasOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, DATA_FEED_ADDRESS) {}
}
