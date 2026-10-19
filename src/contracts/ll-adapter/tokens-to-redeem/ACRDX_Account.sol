// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {CentrifugeAccount} from "../CentrifugeAccount.sol";

import {IACRDX_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IACRDX_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title ACRDX_Account
/// @notice Contract for the ACRDX Liquid Lane account.
contract ACRDX_Account is CentrifugeAccount, IACRDX_Account {
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

/// @title ACRDX_AccountFactory
/// @notice Contract for creating ACRDX Liquid Lane accounts.
contract ACRDX_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
