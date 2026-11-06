// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {OpenEdenTBILLOracle} from "../OpenEdenTBILLOracle.sol";

/// @title TBILL_Oracle
/// @notice Mainnet TBILL oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_162_651_000_000_000_000; bounds 25% / 350%.
contract TBILL_Oracle is OpenEdenTBILLOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 290_662_750_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 4_069_278_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0xdd50C053C096CB04A3e3362E2b622529EC5f2e8a;

    /* CONSTRUCTOR */

    constructor() OpenEdenTBILLOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS) {}
}
