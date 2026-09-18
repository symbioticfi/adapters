// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IAdapterFactory} from "../interfaces/IAdapterFactory.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @title AdapterFactory
/// @notice Migratable factory contract for one adapter family.
contract AdapterFactory is MigratablesFactory, IAdapterFactory {
    /* CONSTRUCTOR */

    constructor(address newOwner) MigratablesFactory(newOwner) {}
}
