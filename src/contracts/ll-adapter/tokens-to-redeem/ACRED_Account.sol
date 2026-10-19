// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AcredSecuritizeAccount} from "../SecuritizeAccount.sol";

import {IACRED_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IACRED_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title ACRED_Account
/// @notice Contract for the ACRED Liquid Lane account.
contract ACRED_Account is AcredSecuritizeAccount, IACRED_Account {
    /* CONSTRUCTOR */

    constructor(address newOracle, address newFactory, address newCowSwapSettlement)
        AcredSecuritizeAccount(
            newOracle,
            newFactory,
            TOKEN_ADDRESS,
            REDEMPTION_WALLET_ADDRESS,
            TOKEN_VALUATION_DELAY,
            TOKEN_POST_CUTOFF_WINDOW,
            newCowSwapSettlement
        )
    {}
}

/// @title ACRED_AccountFactory
/// @notice Contract for creating ACRED Liquid Lane accounts.
contract ACRED_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
