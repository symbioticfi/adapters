// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AsyncRedeemOracle} from "../AsyncRedeemOracle.sol";

/// @title deJTRSY_Oracle
/// @notice Mainnet deJTRSY oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract deJTRSY_Oracle is AsyncRedeemOracle {
    /* CONSTRUCTOR */

    constructor()
        AsyncRedeemOracle(
            257_864_500_000_000_000,
            3_610_103_000_000_000_000,
            0xA6233014B9b7aaa74f38fa1977ffC7A89642dC72,
            0x18Ab9fC0B2e4Fef9e0e03c8EC63BA287a3238257
        )
    {}
}
