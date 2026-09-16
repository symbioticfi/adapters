// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {ChainlinkOracle} from "../oracles/ChainlinkOracle.sol";
import {InfiniFiAccount} from "../InfiniFiAccount.sol";

import {IliUSD4w_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IliUSD4w_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title liUSD4w_Account
/// @notice Contract for the liUSD4w Liquid Lane account.
contract liUSD4w_Account is InfiniFiAccount, IliUSD4w_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        InfiniFiAccount(
            address(
                new ChainlinkOracle(
                    599_319_571_104_044_928,
                    2_397_278_284_416_179_714,
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
            UNWINDING_EPOCHS_4W,
            newCowSwapSettlement
        )
    {}
}

/// @title liUSD4w_AccountFactory
/// @notice Contract for creating liUSD4w Liquid Lane accounts.
contract liUSD4w_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
