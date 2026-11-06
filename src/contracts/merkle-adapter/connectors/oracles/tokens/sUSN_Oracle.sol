// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {NoonOracle} from "../NoonOracle.sol";

/// @title sUSN_Oracle
/// @notice Mainnet sUSN oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_234_780_000_000_000_000; bounds 50% / 250%.
contract sUSN_Oracle is NoonOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 617_390_000_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_086_950_000_000_000_000;
    address private constant TOKEN_ADDRESS = 0xE24a3DC889621612422A64E6388927901608B91D;
    address private constant REDEEM_HANDLER_ADDRESS = 0x9F8D0a683871125083170F65430F8A15aFfa0086;
    address private constant QUOTE_TOKEN_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /* CONSTRUCTOR */

    constructor()
        NoonOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS, REDEEM_HANDLER_ADDRESS, QUOTE_TOKEN_ADDRESS)
    {}
}
