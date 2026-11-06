// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AsyncRedeemOracle} from "../AsyncRedeemOracle.sol";

/// @title JTRSY_Oracle
/// @notice Mainnet JTRSY oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract JTRSY_Oracle is AsyncRedeemOracle {
    /* CONSTRUCTOR */

    constructor()
        AsyncRedeemOracle(
            277_562_500_000_000_000,
            3_885_875_000_000_000_000,
            0x8c213ee79581Ff4984583C6a801e5263418C4b86,
            0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A
        )
    {}
}
