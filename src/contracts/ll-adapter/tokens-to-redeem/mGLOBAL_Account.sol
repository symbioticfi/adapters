// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {CutoffMidasAccount} from "../MidasAccount.sol";
import {MidasOracle} from "../oracles/MidasOracle.sol";

import {ImGLOBAL_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/ImGLOBAL_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title mGLOBAL_Account
/// @notice Contract for the mGLOBAL Liquid Lane account.
contract mGLOBAL_Account is CutoffMidasAccount, ImGLOBAL_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement, address newDataFeed)
        CutoffMidasAccount(
            address(new MidasOracle(251_441_200_000_000_000, 3_520_176_800_000_000_000, newDataFeed)),
            newFactory,
            TOKEN_COOLDOWN,
            TOKEN_INITIAL_CUTOFF,
            TOKEN_ADDRESS,
            TOKEN_PRE_CUTOFF_WINDOW,
            MAINNET_USDC,
            REDEMPTION_VAULT_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title mGLOBAL_AccountFactory
/// @notice Contract for creating mGLOBAL Liquid Lane accounts.
contract mGLOBAL_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
