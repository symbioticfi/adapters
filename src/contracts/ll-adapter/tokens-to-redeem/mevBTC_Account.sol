// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasCompAccount} from "../MidasAccount.sol";
import {MidasOracle} from "../oracles/MidasOracle.sol";

import {IMidasRedemptionVault} from "../../../interfaces/ll-adapter/midas/IMidasRedemptionVault.sol";
import {ImevBTC_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/ImevBTC_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title mevBTC_Account
/// @notice Contract for the mevBTC Liquid Lane account.
contract mevBTC_Account is MidasCompAccount, ImevBTC_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        MidasCompAccount(
            address(
                new MidasOracle(
                    511_811_155_000_000_000,
                    2_047_244_620_000_000_000,
                    IMidasRedemptionVault(REDEMPTION_VAULT_ADDRESS).mTokenDataFeed()
                )
            ),
            newFactory,
            TOKEN_COOLDOWN,
            TOKEN_ADDRESS,
            WBTC,
            REDEMPTION_VAULT_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title mevBTC_AccountFactory
/// @notice Contract for creating mevBTC Liquid Lane accounts.
contract mevBTC_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
