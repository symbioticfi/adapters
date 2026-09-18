// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {CentrifugeAccount} from "../CentrifugeAccount.sol";

import {IHYB_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IHYB_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title HYB_Account
/// @notice Contract for the HYB Liquid Lane account.
contract HYB_Account is CentrifugeAccount, IHYB_Account {
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

/// @title HYB_AccountFactory
/// @notice Contract for creating HYB Liquid Lane accounts.
contract HYB_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
