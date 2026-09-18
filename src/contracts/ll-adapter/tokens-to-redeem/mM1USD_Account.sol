// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasCompAccount} from "../MidasAccount.sol";
import {MidasOracle} from "../oracles/MidasOracle.sol";

import {IMidasRedemptionVault} from "../../../interfaces/ll-adapter/midas/IMidasRedemptionVault.sol";
import {ImM1USD_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/ImM1USD_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title mM1USD_Account
/// @notice Contract for the mM1USD Liquid Lane account.
contract mM1USD_Account is MidasCompAccount, ImM1USD_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        MidasCompAccount(
            address(
                new MidasOracle(
                    253_500_000_000_000_000,
                    3_548_800_000_000_000_000,
                    IMidasRedemptionVault(REDEMPTION_VAULT_ADDRESS).mTokenDataFeed()
                )
            ),
            newFactory,
            TOKEN_COOLDOWN,
            TOKEN_ADDRESS,
            MAINNET_USDC,
            REDEMPTION_VAULT_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title mM1USD_AccountFactory
/// @notice Contract for creating mM1USD Liquid Lane accounts.
contract mM1USD_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
