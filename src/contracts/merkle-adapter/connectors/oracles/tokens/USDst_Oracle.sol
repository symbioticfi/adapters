// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ERC4626Oracle} from "../ERC4626Oracle.sol";

/// @title USDst_Oracle
/// @notice Mainnet USDst oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_005_487_000_000_000_000; bounds 25% / 350%.
contract USDst_Oracle is ERC4626Oracle {
    /* CONSTRUCTOR */

    constructor()
        ERC4626Oracle(251_371_750_000_000_000, 3_519_204_500_000_000_000, 0xcDA323c2DF692d989B24BA51D0aCCa924cf9a344)
    {}
}
