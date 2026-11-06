// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ERC4626Oracle} from "../ERC4626Oracle.sol";

/// @title NineSummitsUSDC_Oracle
/// @notice Mainnet NineSummitsUSDC oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_177_211_000_000_000_000; bounds 25% / 350%.
contract NineSummitsUSDC_Oracle is ERC4626Oracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 294_302_750_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 4_120_238_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0x03D1eC0D01b659b89a87eAbb56e4AF5Cb6e14BFc;

    /* CONSTRUCTOR */

    constructor() ERC4626Oracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS) {}
}
