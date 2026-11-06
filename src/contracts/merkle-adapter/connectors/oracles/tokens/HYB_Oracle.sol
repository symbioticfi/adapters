// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AsyncRedeemOracle} from "../AsyncRedeemOracle.sol";

/// @title HYB_Oracle
/// @notice Mainnet HYB oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract HYB_Oracle is AsyncRedeemOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 250_943_250_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_513_205_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0x4827C7ecce4f07ADfe44A97165f06A199e7d2505;
    address private constant ASYNC_REDEEM_VAULT_ADDRESS = 0xFeb5A9D7ADBbA65168B0FaBA90675F7c96fcA85a;

    /* CONSTRUCTOR */

    constructor() AsyncRedeemOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS, ASYNC_REDEEM_VAULT_ADDRESS) {}
}
