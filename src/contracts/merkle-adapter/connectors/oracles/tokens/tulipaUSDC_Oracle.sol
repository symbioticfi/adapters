// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ERC4626Oracle} from "../ERC4626Oracle.sol";

/// @title tulipaUSDC_Oracle
/// @notice Mainnet tulipaUSDC oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_071_300_000_000_000_000; bounds 25% / 350%.
contract tulipaUSDC_Oracle is ERC4626Oracle {
    /* CONSTRUCTOR */

    constructor()
        ERC4626Oracle(267_825_000_000_000_000, 3_749_550_000_000_000_000, 0xcE0b790ae0d8cF91e01f3FB69025e14569b574f3)
    {}
}
