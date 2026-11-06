// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasOracle} from "../MidasOracle.sol";

/// @title mHyperETH_Oracle
/// @notice Mainnet mHyperETH oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_018_966_290_000_000_000; bounds 50% / 200%.
contract mHyperETH_Oracle is MidasOracle {
    /* CONSTRUCTOR */

    constructor()
        MidasOracle(509_483_145_000_000_000, 2_037_932_580_000_000_000, 0xbD560c1E87752717C34912D128168BfE26021EA2)
    {}
}
