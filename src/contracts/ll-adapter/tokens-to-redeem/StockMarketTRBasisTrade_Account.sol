// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {MidasCompAccount} from "../MidasAccount.sol";
import {MidasOracle} from "../oracles/MidasOracle.sol";

import {IMidasRedemptionVault} from "../../../interfaces/ll-adapter/midas/IMidasRedemptionVault.sol";
import {
    IStockMarketTRBasisTrade_Account
} from "../../../interfaces/ll-adapter/tokens-to-redeem/IStockMarketTRBasisTrade_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title StockMarketTRBasisTrade_Account
/// @notice Contract for the StockMarketTRBasisTrade Liquid Lane account.
contract StockMarketTRBasisTrade_Account is MidasCompAccount, IStockMarketTRBasisTrade_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        MidasCompAccount(
            address(
                new MidasOracle(
                    253_000_000_000_000_000,
                    3_541_400_000_000_000_000,
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

/// @title StockMarketTRBasisTrade_AccountFactory
/// @notice Contract for creating StockMarketTRBasisTrade Liquid Lane accounts.
contract StockMarketTRBasisTrade_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
