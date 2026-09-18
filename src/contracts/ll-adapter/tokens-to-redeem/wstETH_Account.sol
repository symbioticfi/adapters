// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {LidoAccount} from "../LidoAccount.sol";
import {WstETHOracle} from "../oracles/WstETHOracle.sol";

import {IwstETH_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IwstETH_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title wstETH_Account
/// @notice Contract for the wstETH Liquid Lane account.
contract wstETH_Account is LidoAccount, IwstETH_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        LidoAccount(
            STETH_ADDRESS,
            WETH_ADDRESS,
            address(new WstETHOracle(0.5e18, 2.5e18, TOKEN_ADDRESS)),
            TOKEN_ADDRESS,
            newFactory,
            WITHDRAWAL_QUEUE_ADDRESS,
            newCowSwapSettlement
        )
    {}
}

/// @title wstETH_AccountFactory
/// @notice Contract for creating wstETH Liquid Lane accounts.
contract wstETH_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
