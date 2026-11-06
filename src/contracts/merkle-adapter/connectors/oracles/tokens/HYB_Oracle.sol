// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AsyncRedeemOracle} from "../AsyncRedeemOracle.sol";

/// @title HYB_Oracle
/// @notice Mainnet HYB oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract HYB_Oracle is AsyncRedeemOracle {
    /* CONSTRUCTOR */

    constructor()
        AsyncRedeemOracle(
            250_943_250_000_000_000,
            3_513_205_500_000_000_000,
            0x4827C7ecce4f07ADfe44A97165f06A199e7d2505,
            0xFeb5A9D7ADBbA65168B0FaBA90675F7c96fcA85a
        )
    {}
}
