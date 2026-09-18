// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {ThreeJaneAccount} from "../ThreeJaneAccount.sol";
import {ThreeJaneOracle} from "../oracles/ThreeJaneOracle.sol";

import {IUSD3_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IUSD3_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title USD3_Account
/// @notice Contract for the USD3 Liquid Lane account.
contract USD3_Account is ThreeJaneAccount, IUSD3_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        ThreeJaneAccount(
            address(new ThreeJaneOracle(MIN_PRICE, MAX_PRICE, TOKEN_ADDRESS)),
            newFactory,
            TOKEN_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title USD3_AccountFactory
/// @notice Contract for creating USD3 Liquid Lane accounts.
contract USD3_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
