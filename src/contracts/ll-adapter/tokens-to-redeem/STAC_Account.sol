// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {ChainlinkOracle} from "../oracles/ChainlinkOracle.sol";
import {SecuritizeNoticeAccount} from "../SecuritizeNoticeAccount.sol";

import {ISTAC_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/ISTAC_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title STAC_Account
/// @notice Contract for the STAC Liquid Lane account.
contract STAC_Account is SecuritizeNoticeAccount, ISTAC_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        SecuritizeNoticeAccount(
            address(
                new ChainlinkOracle(
                    MIN_PRICE, MAX_PRICE, [NAV_FEED_ADDRESS, address(0)], [FEED_STALENESS_DURATION, uint48(0)]
                )
            ),
            newFactory,
            TOKEN_ADDRESS,
            REDEMPTION_WALLET_ADDRESS,
            TOKEN_SETTLEMENT_DURATION,
            newCowSwapSettlement
        )
    {}
}

/// @title STAC_AccountFactory
/// @notice Contract for creating STAC Liquid Lane accounts.
contract STAC_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
