// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {DigiFTAccount} from "../DigiFTAccount.sol";

import {IbEQTY_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IbEQTY_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title bEQTY_Account
/// @notice Contract for the bEQTY Liquid Lane account.
contract bEQTY_Account is DigiFTAccount, IbEQTY_Account {
    /* CONSTRUCTOR */

    constructor(address newOracle, address newFactory, address newCowSwapSettlement)
        DigiFTAccount(
            newOracle,
            newFactory,
            TOKEN_ADDRESS,
            SUB_RED_MANAGEMENT_ADDRESS,
            TOKEN_SETTLEMENT_DURATION,
            newCowSwapSettlement
        )
    {}
}

/// @title bEQTY_AccountFactory
/// @notice Contract for creating bEQTY Liquid Lane accounts.
contract bEQTY_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
