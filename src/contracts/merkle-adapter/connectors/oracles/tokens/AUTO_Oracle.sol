// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {FigureOracle} from "../FigureOracle.sol";

/// @title AUTO_Oracle
/// @notice Mainnet AUTO oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_031_312_000_000_000_000; bounds 25% / 350%.
contract AUTO_Oracle is FigureOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 257_828_000_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_609_592_000_000_000_000;
    address private constant TOKEN_ADDRESS = 0x997E2Efbce91D170B00EA402e35a66C887EE1da9;

    /* CONSTRUCTOR */

    constructor() FigureOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS) {}
}
