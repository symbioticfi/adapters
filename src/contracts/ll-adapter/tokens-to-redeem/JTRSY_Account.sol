// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {CentrifugeAccount} from "../CentrifugeAccount.sol";

import {IJTRSY_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IJTRSY_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title JTRSY_Account
/// @notice Contract for the JTRSY Liquid Lane account.
contract JTRSY_Account is CentrifugeAccount, IJTRSY_Account {
    /* CONSTRUCTOR */

    constructor(
        address newOracle,
        address newFactory,
        address newRedemptionToken,
        address newAsyncRedeemVault,
        address newCowSwapSettlement
    )
        CentrifugeAccount(
            newOracle,
            newFactory,
            TOKEN_COOLDOWN,
            TOKEN_ADDRESS,
            newRedemptionToken,
            newAsyncRedeemVault,
            newCowSwapSettlement
        )
    {}
}

/// @title JTRSY_AccountFactory
/// @notice Contract for creating JTRSY Liquid Lane accounts.
contract JTRSY_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
