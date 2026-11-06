// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ERC4626Oracle} from "../ERC4626Oracle.sol";

/// @title gamiUSDC_Oracle
/// @notice Mainnet gamiUSDC oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_101_588_000_000_000_000; bounds 25% / 350%.
contract gamiUSDC_Oracle is ERC4626Oracle {
    /* CONSTRUCTOR */

    constructor()
        ERC4626Oracle(275_397_000_000_000_000, 3_855_558_000_000_000_000, 0xdAe854D0896ad2fEE335689A3F7B4a95fd1a3E46)
    {}
}
