// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mEVUSD_Oracle
/// @notice Mainnet mEVUSD oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_045_378_070_000_000_000; bounds 50% / 200%.
contract mEVUSD_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(522_689_035_000_000_000, 2_090_756_140_000_000_000, 0x508Fe9556C7919E64406bB4042760d7Bb1F40fC9)
    {}
}
