// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {OpenEdenTBILLOracle} from "../OpenEdenTBILLOracle.sol";

/// @title TBILL_Oracle
/// @notice Mainnet TBILL oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_162_651_000_000_000_000; bounds 25% / 350%.
contract TBILL_Oracle is OpenEdenTBILLOracle {
    /* CONSTRUCTOR */

    constructor()
        OpenEdenTBILLOracle(
            290_662_750_000_000_000, 4_069_278_500_000_000_000, 0xdd50C053C096CB04A3e3362E2b622529EC5f2e8a
        )
    {}
}
