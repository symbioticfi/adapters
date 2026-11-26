// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ChainlinkOracle} from "../ChainlinkOracle.sol";

/// @notice Returns Securitize HINC's USD NAV per share, scaled to 18 decimals.
contract HINC_Oracle is ChainlinkOracle {
    constructor()
        ChainlinkOracle(
            243.505_930_25 ether,
            3409.083_023_5 ether,
            [0xbD284A0338ba4bd09Ec13Cd18Fd275442456C6d6, address(0)],
            [uint48(48 hours), uint48(0)]
        )
    {}
}
