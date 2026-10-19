// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MakinaAccount} from "../MakinaAccount.sol";
import {MakinaOracle} from "../oracles/MakinaOracle.sol";

import {IDUSD_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IDUSD_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title DUSD_Account
/// @notice Contract for the DUSD Liquid Lane account.
contract DUSD_Account is MakinaAccount, IDUSD_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        MakinaAccount(
            address(
                new MakinaOracle(
                    515_533_500_000_000_000,
                    2_062_134_000_000_000_000,
                    SHARE_PRICE_ORACLE_ADDRESS,
                    MACHINE_ADDRESS,
                    ORACLE_STALENESS_DURATION
                )
            ),
            newFactory,
            TOKEN_COOLDOWN,
            REDEEMER_ADDRESS,
            TOKEN_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title DUSD_AccountFactory
/// @notice Contract for creating DUSD Liquid Lane accounts.
contract DUSD_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
