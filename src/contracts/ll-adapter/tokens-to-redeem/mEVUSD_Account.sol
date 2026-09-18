// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MidasCompAccount} from "../MidasAccount.sol";
import {MidasOracle} from "../oracles/MidasOracle.sol";

import {IMidasRedemptionVault} from "../../../interfaces/ll-adapter/midas/IMidasRedemptionVault.sol";
import {ImEVUSD_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/ImEVUSD_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title mEVUSD_Account
/// @notice Contract for the mEVUSD Liquid Lane account.
contract mEVUSD_Account is MidasCompAccount, ImEVUSD_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        MidasCompAccount(
            address(
                new MidasOracle(
                    522_689_035_000_000_000,
                    2_090_756_140_000_000_000,
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

/// @title mEVUSD_AccountFactory
/// @notice Contract for creating mEVUSD Liquid Lane accounts.
contract mEVUSD_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
