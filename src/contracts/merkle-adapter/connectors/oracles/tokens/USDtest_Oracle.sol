// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ERC4626Oracle} from "../ERC4626Oracle.sol";

/// @title USDtest_Oracle
/// @notice Mainnet USDtest oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_005_166_000_000_000_000; bounds 25% / 350%.
contract USDtest_Oracle is ERC4626Oracle {
    /* CONSTRUCTOR */

    constructor()
        ERC4626Oracle(251_291_500_000_000_000, 3_518_081_000_000_000_000, 0x78295b34d940C780c8c02A607FEDF58242E7df2c)
    {}
}
