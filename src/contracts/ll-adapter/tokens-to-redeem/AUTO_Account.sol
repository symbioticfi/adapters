// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {FigureAccount} from "../FigureAccount.sol";

import {IAUTO_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IAUTO_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title AUTO_Account
/// @notice Contract for the AUTO Liquid Lane account.
contract AUTO_Account is FigureAccount, IAUTO_Account {
    /* CONSTRUCTOR */

    constructor(
        address newOracle,
        address newFactory,
        address newTokenToRedeem,
        address newSubAccountImplementation,
        address newCowSwapSettlement
    )
        FigureAccount(
            newOracle, newFactory, TOKEN_COOLDOWN, newTokenToRedeem, newSubAccountImplementation, newCowSwapSettlement
        )
    {}
}

/// @title AUTO_AccountFactory
/// @notice Contract for creating AUTO Liquid Lane accounts.
contract AUTO_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
