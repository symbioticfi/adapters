// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ERC4626Oracle} from "../ERC4626Oracle.sol";

/// @title MtPoolUSD_Oracle
/// @notice Mainnet MtPoolUSD oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_043_614_000_000_000_000; bounds 25% / 350%.
contract MtPoolUSD_Oracle is ERC4626Oracle {
    /* CONSTRUCTOR */

    constructor()
        ERC4626Oracle(260_903_500_000_000_000, 3_652_649_000_000_000_000, 0x28663161f9FA2963EB6102b88a741E195E974dF6)
    {}
}
