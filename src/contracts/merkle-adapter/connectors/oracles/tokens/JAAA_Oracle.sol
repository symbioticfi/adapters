// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AsyncRedeemOracle} from "../AsyncRedeemOracle.sol";

/// @title JAAA_Oracle
/// @notice Mainnet JAAA oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract JAAA_Oracle is AsyncRedeemOracle {
    /* CONSTRUCTOR */

    constructor()
        AsyncRedeemOracle(
            260_413_500_000_000_000,
            3_645_789_000_000_000_000,
            0x5a0F93D040De44e78F251b03c43be9CF317Dcf64,
            0x4880799eE5200fC58DA299e965df644fBf46780B
        )
    {}
}
