// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {ChainlinkOracle} from "../oracles/ChainlinkOracle.sol";
import {SpikoAccount} from "../SpikoAccount.sol";

import {ISPKCC_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/ISPKCC_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title SPKCC_Account
/// @notice Contract for the SPKCC Liquid Lane account.
contract SPKCC_Account is SpikoAccount, ISPKCC_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        SpikoAccount(
            address(
                new ChainlinkOracle(
                    MIN_PRICE, MAX_PRICE, [NAV_FEED_ADDRESS, address(0)], [FEED_STALENESS_DURATION, uint48(0)]
                )
            ),
            newFactory,
            TOKEN_ADDRESS,
            REDEMPTION_ADDRESS,
            SETTLEMENT_TOKEN_ADDRESS,
            TOKEN_SETTLEMENT_DURATION,
            newCowSwapSettlement
        )
    {}
}

/// @title SPKCC_AccountFactory
/// @notice Contract for creating SPKCC Liquid Lane accounts.
contract SPKCC_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
