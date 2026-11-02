// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {EtherFiAccount} from "../EtherFiAccount.sol";
import {WeETHOracle} from "../oracles/WeETHOracle.sol";

import {IweETH_Account} from "../../../interfaces/ll-adapter/tokens-to-redeem/IweETH_Account.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title weETH_Account
/// @notice Contract for the weETH Liquid Lane account.
contract weETH_Account is EtherFiAccount, IweETH_Account {
    /* CONSTRUCTOR */

    constructor(address newFactory, address newCowSwapSettlement)
        EtherFiAccount(
            EETH_ADDRESS,
            WETH_ADDRESS,
            address(new WeETHOracle(0.5e18, 2.5e18, TOKEN_ADDRESS)),
            newFactory,
            LIQUIDITY_POOL_ADDRESS,
            TOKEN_ADDRESS,
            REDEMPTION_MANAGER_ADDRESS,
            newCowSwapSettlement,
            WITHDRAW_REQUEST_NFT_ADDRESS
        )
    {}
}

/// @title weETH_AccountFactory
/// @notice Contract for creating weETH Liquid Lane accounts.
contract weETH_AccountFactory is MigratablesFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
