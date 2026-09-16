// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {ChainlinkOracle} from "../oracles/ChainlinkOracle.sol";
import {InfiniFiAccount} from "../InfiniFiAccount.sol";

import {IliUSD13w_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IliUSD13w_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title liUSD13w_Account
/// @notice Contract for the liUSD13w Liquid Lane account.
contract liUSD13w_Account is InfiniFiAccount, IliUSD13w_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        InfiniFiAccount(
            address(
                new ChainlinkOracle(
                    610_302_338_122_868_364,
                    2_441_209_352_491_473_456,
                    [BUCKET_FEED_ADDRESS, address(0)],
                    [FEED_STALENESS_DURATION, uint48(0)]
                )
            ),
            newFactory,
            TOKEN_COOLDOWN,
            TOKEN_ADDRESS,
            GATEWAY_ADDRESS,
            UNWINDING_MODULE_ADDRESS,
            IUSD_ADDRESS,
            UNWINDING_EPOCHS_13W,
            newCowSwapSettlement
        )
    {}
}

/// @title liUSD13w_AccountFactory
/// @notice Contract for creating liUSD13w Liquid Lane accounts.
contract liUSD13w_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
