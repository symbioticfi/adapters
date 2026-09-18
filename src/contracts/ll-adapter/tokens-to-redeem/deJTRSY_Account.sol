// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {CentrifugeAccount} from "../CentrifugeAccount.sol";

import {IdeJTRSY_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IdeJTRSY_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title deJTRSY_Account
/// @notice Contract for the deJTRSY Liquid Lane account.
contract deJTRSY_Account is CentrifugeAccount, IdeJTRSY_Account {
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

/// @title deJTRSY_AccountFactory
/// @notice Contract for creating deJTRSY Liquid Lane accounts.
contract deJTRSY_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
