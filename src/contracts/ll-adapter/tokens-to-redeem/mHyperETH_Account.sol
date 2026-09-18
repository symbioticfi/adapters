// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasCompAccount} from "../MidasAccount.sol";
import {MidasOracle} from "../oracles/MidasOracle.sol";

import {IMidasRedemptionVault} from "../../../interfaces/ll-adapter/midas/IMidasRedemptionVault.sol";
import {ImHyperETH_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/ImHyperETH_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title mHyperETH_Account
/// @notice Contract for the mHyperETH Liquid Lane account.
contract mHyperETH_Account is MidasCompAccount, ImHyperETH_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        MidasCompAccount(
            address(
                new MidasOracle(
                    512_254_525_000_000_000,
                    2_049_018_100_000_000_000,
                    IMidasRedemptionVault(REDEMPTION_VAULT_ADDRESS).mTokenDataFeed()
                )
            ),
            newFactory,
            TOKEN_COOLDOWN,
            TOKEN_ADDRESS,
            WETH,
            REDEMPTION_VAULT_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title mHyperETH_AccountFactory
/// @notice Contract for creating mHyperETH Liquid Lane accounts.
contract mHyperETH_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
