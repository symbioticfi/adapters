// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {SuperstateAccount} from "../SuperstateAccount.sol";

import {IUSCC_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IUSCC_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title USCC_Account
/// @notice Contract for the USCC Liquid Lane account.
contract USCC_Account is SuperstateAccount, IUSCC_Account {
    /* CONSTRUCTOR */

    constructor(address newOracle, address newFactory, address newCowSwapSettlement)
        SuperstateAccount(
            newOracle, newFactory, TOKEN_COOLDOWN, TOKEN_ADDRESS, TOKEN_SETTLEMENT_DURATION, newCowSwapSettlement
        )
    {}
}

/// @title USCC_AccountFactory
/// @notice Contract for creating USCC Liquid Lane accounts.
contract USCC_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
