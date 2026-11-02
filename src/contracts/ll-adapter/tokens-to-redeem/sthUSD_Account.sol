// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ERC4626Oracle} from "../oracles/ERC4626Oracle.sol";
import {TheoAccount} from "../TheoAccount.sol";

import {IsthUSD_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IsthUSD_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title sthUSD_Account
/// @notice Contract for the sthUSD Liquid Lane account.
contract sthUSD_Account is TheoAccount, IsthUSD_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        TheoAccount(
            address(new ERC4626Oracle(MIN_PRICE, MAX_PRICE, TOKEN_ADDRESS)),
            newFactory,
            TOKEN_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title sthUSD_AccountFactory
/// @notice Contract for creating sthUSD Liquid Lane accounts.
contract sthUSD_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
