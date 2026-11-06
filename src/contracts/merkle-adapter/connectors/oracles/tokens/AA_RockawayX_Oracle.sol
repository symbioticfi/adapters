// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ParetoOracle} from "../ParetoOracle.sol";

/// @title AA_RockawayX_Oracle
/// @notice Mainnet AA_RockawayX oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_104_239_000_000_000_000; bounds 25% / 350%.
contract AA_RockawayX_Oracle is ParetoOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 276_059_750_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_864_836_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0xEC6a70F62a83418c7fb238182eD2865F80491a8B;
    address private constant IDLE_CDO_ADDRESS = 0x9cF358aff79DeA96070A85F00c0AC79569970Ec3;

    /* CONSTRUCTOR */

    constructor() ParetoOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS, IDLE_CDO_ADDRESS) {}
}
