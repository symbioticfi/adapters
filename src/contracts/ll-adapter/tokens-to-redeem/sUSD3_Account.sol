// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {SThreeJaneAccount} from "../SThreeJaneAccount.sol";
import {SThreeJaneOracle} from "../oracles/SThreeJaneOracle.sol";

import {IsUSD3_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IsUSD3_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title sUSD3_Account
/// @notice Contract for the sUSD3 Liquid Lane account.
contract sUSD3_Account is SThreeJaneAccount, IsUSD3_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        SThreeJaneAccount(
            address(new SThreeJaneOracle(MIN_PRICE, MAX_PRICE, TOKEN_ADDRESS)),
            newFactory,
            TOKEN_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title sUSD3_AccountFactory
/// @notice Contract for creating sUSD3 Liquid Lane accounts.
contract sUSD3_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
