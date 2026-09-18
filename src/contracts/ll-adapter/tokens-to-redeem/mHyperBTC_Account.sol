// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {MidasCompAccount} from "../MidasAccount.sol";
import {MidasOracle} from "../oracles/MidasOracle.sol";

import {IMidasRedemptionVault} from "../../../interfaces/ll-adapter/midas/IMidasRedemptionVault.sol";
import {ImHyperBTC_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/ImHyperBTC_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title mHyperBTC_Account
/// @notice Contract for the mHyperBTC Liquid Lane account.
contract mHyperBTC_Account is MidasCompAccount, ImHyperBTC_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        MidasCompAccount(
            address(
                new MidasOracle(
                    510_936_340_000_000_000,
                    2_043_745_360_000_000_000,
                    IMidasRedemptionVault(REDEMPTION_VAULT_ADDRESS).mTokenDataFeed()
                )
            ),
            newFactory,
            TOKEN_COOLDOWN,
            TOKEN_ADDRESS,
            CBBTC,
            REDEMPTION_VAULT_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title mHyperBTC_AccountFactory
/// @notice Contract for creating mHyperBTC Liquid Lane accounts.
contract mHyperBTC_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
