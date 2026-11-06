// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ERC4626Oracle} from "../ERC4626Oracle.sol";

/// @title USDst_Oracle
/// @notice Mainnet USDst oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_005_487_000_000_000_000; bounds 25% / 350%.
contract USDst_Oracle is ERC4626Oracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 251_371_750_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_519_204_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0xcDA323c2DF692d989B24BA51D0aCCa924cf9a344;

    /* CONSTRUCTOR */

    constructor() ERC4626Oracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS) {}
}
