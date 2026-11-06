// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ParetoOracle} from "../ParetoOracle.sol";

/// @title AA_Bastion_Oracle
/// @notice Mainnet AA_Bastion oracle with fixed source and price bounds.
/// @dev Reference block 26355737: 1_174_275_000_000_000_000; bounds 25% / 350%.
contract AA_Bastion_Oracle is ParetoOracle {
    /* CONSTANTS */

    uint256 private constant MIN_PRICE_BOUND = 293_568_750_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 4_109_962_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0xC49b4ECc14aa31Ef0AD077EdcF53faB4201b724c;
    address private constant IDLE_CDO_ADDRESS = 0x4462eD748B8F7985A4aC6b538Dfc105Fce2dD165;

    /* CONSTRUCTOR */

    constructor() ParetoOracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS, IDLE_CDO_ADDRESS) {}
}
