// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {ChainlinkOracle} from "../oracles/ChainlinkOracle.sol";
import {SecuritizeOffRampAccount} from "../SecuritizeOffRampAccount.sol";

import {IVBILL_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IVBILL_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title VBILL_Account
/// @notice Contract for the VBILL Liquid Lane account.
contract VBILL_Account is SecuritizeOffRampAccount, IVBILL_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        SecuritizeOffRampAccount(
            address(
                new ChainlinkOracle(
                    MIN_PRICE, MAX_PRICE, [NAV_FEED_ADDRESS, address(0)], [FEED_STALENESS_DURATION, uint48(0)]
                )
            ),
            newFactory,
            TOKEN_ADDRESS,
            OFF_RAMP_ADDRESS,
            SETTLEMENT_TOKEN_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title VBILL_AccountFactory
/// @notice Contract for creating VBILL Liquid Lane accounts.
contract VBILL_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
