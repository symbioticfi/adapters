// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {ParetoAccount} from "../ParetoAccount.sol";

import {IAA_FalconX_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IAA_FalconX_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title AA_FalconX_Account
/// @notice Contract for the AA_FalconX Liquid Lane account.
contract AA_FalconX_Account is ParetoAccount, IAA_FalconX_Account {
    /* CONSTRUCTOR */

    constructor(address newOracle, address newFactory, address newCowSwapSettlement)
        ParetoAccount(newOracle, newFactory, TOKEN_ADDRESS, WITHDRAWAL_QUEUE_ADDRESS, newCowSwapSettlement)
    {}
}

/// @title AA_FalconX_AccountFactory
/// @notice Contract for creating AA_FalconX Liquid Lane accounts.
contract AA_FalconX_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
