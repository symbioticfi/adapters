// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {NoonAccount} from "../NoonAccount.sol";
import {NoonOracle} from "../oracles/NoonOracle.sol";

import {IsUSN_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IsUSN_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title sUSN_Account
/// @notice Contract for the sUSN Liquid Lane account.
contract sUSN_Account is NoonAccount, IsUSN_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        NoonAccount(
            address(new NoonOracle(MIN_PRICE, MAX_PRICE, RATE_PROVIDER_ADDRESS, TOKEN_ADDRESS)),
            newFactory,
            TOKEN_COOLDOWN,
            TOKEN_ADDRESS,
            WITHDRAWAL_HANDLER_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title sUSN_AccountFactory
/// @notice Contract for creating sUSN Liquid Lane accounts.
contract sUSN_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
