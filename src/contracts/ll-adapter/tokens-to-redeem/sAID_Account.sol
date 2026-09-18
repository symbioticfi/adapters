// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {GaibAccount} from "../GaibAccount.sol";
import {SaidOracle} from "../oracles/SaidOracle.sol";

import {IsAID_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IsAID_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title sAID_Account
/// @notice Contract for the sAID Liquid Lane account.
contract sAID_Account is GaibAccount, IsAID_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        GaibAccount(
            address(new SaidOracle(527_574_236_280_171_822, 2_110_296_945_120_687_290, TOKEN_ADDRESS)),
            newFactory,
            TOKEN_COOLDOWN,
            TOKEN_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title sAID_AccountFactory
/// @notice Contract for creating sAID Liquid Lane accounts.
contract sAID_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
