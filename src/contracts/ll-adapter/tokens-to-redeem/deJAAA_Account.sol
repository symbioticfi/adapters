// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {CentrifugeAccount} from "../CentrifugeAccount.sol";

import {IdeJAAA_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IdeJAAA_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title deJAAA_Account
/// @notice Contract for the deJAAA Liquid Lane account.
contract deJAAA_Account is CentrifugeAccount, IdeJAAA_Account {
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

/// @title deJAAA_AccountFactory
/// @notice Contract for creating deJAAA Liquid Lane accounts.
contract deJAAA_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
