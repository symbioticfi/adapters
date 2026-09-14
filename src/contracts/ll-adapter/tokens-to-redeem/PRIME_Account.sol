// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {FigureAccount} from "../FigureAccount.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

contract PRIME_Account is FigureAccount {
    uint48 internal constant TOKEN_COOLDOWN = 18 hours;

    constructor(
        address oracle,
        address factory,
        address tokenToRedeem,
        address subAccountImplementation,
        address cowSwapSettlement
    ) FigureAccount(oracle, factory, TOKEN_COOLDOWN, tokenToRedeem, subAccountImplementation, cowSwapSettlement) {}
}

contract PRIME_AccountFactory is MigratablesFactory {
    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
