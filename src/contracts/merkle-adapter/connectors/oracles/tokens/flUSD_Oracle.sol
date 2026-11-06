// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ERC4626Oracle} from "../ERC4626Oracle.sol";

/// @title flUSD_Oracle
/// @notice Mainnet flUSD oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_001_877_000_000_000_000; bounds 25% / 350%.
contract flUSD_Oracle is ERC4626Oracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 250_469_250_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_506_569_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0xD2386D8413C2eC4A761901dA14C74A98eBe5054B;

    /* CONSTRUCTOR */

    constructor() ERC4626Oracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS) {}
}
