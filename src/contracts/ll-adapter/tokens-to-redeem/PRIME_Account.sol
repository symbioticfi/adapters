// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {FigureAccount} from "../FigureAccount.sol";

import {IPRIME_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IPRIME_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title PRIME_Account
/// @notice Contract for the PRIME Liquid Lane account.
contract PRIME_Account is FigureAccount, IPRIME_Account {
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

/// @title PRIME_AccountFactory
/// @notice Contract for creating PRIME Liquid Lane accounts.
contract PRIME_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
