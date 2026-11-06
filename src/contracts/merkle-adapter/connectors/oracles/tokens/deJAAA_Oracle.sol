// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AsyncRedeemOracle} from "../AsyncRedeemOracle.sol";

/// @title deJAAA_Oracle
/// @notice Mainnet deJAAA oracle with fixed source and price bounds.
/// @dev Preserves the deployed LL oracle source and bounds.
contract deJAAA_Oracle is AsyncRedeemOracle {
    /* CONSTRUCTOR */

    constructor()
        AsyncRedeemOracle(
            260_037_000_000_000_000,
            3_640_518_000_000_000_000,
            0xAAA0008C8CF3A7Dca931adaF04336A5D808C82Cc,
            0x4865BC9701fBD1207A7B50e2aF442C7DAf154c9c
        )
    {}
}
