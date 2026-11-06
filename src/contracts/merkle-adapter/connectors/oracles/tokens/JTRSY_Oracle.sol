// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AsyncRedeemOracle} from "../AsyncRedeemOracle.sol";

/// @title JTRSY_Oracle
/// @notice Mainnet JTRSY oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract JTRSY_Oracle is AsyncRedeemOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 277_562_500_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_885_875_000_000_000_000;
    address private constant TOKEN_ADDRESS = 0x8c213ee79581Ff4984583C6a801e5263418C4b86;
    address private constant ASYNC_REDEEM_VAULT_ADDRESS = 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A;

    /* CONSTRUCTOR */

    constructor() AsyncRedeemOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS, ASYNC_REDEEM_VAULT_ADDRESS) {}
}
