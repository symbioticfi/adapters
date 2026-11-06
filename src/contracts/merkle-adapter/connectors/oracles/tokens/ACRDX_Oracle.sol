// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AsyncRedeemOracle} from "../AsyncRedeemOracle.sol";

/// @title ACRDX_Oracle
/// @notice Mainnet ACRDX oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_022_263_000_000_000_000; bounds 25% / 350%.
contract ACRDX_Oracle is AsyncRedeemOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 255_565_750_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_577_920_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0x9477724Bb54AD5417de8Baff29e59DF3fB4DA74f;
    address private constant ASYNC_REDEEM_VAULT_ADDRESS = 0x74A739EA1Dc67c5a0179ebad665D1D3c4b80B712;

    /* CONSTRUCTOR */

    constructor() AsyncRedeemOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS, ASYNC_REDEEM_VAULT_ADDRESS) {}
}
