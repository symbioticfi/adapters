// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {
    IAaveHealthFactor,
    IAaveHealthPool
} from "../../../interfaces/merkle_adapter/borrow_capability/IAaveHealthFactor.sol";

/// @title AaveHealthFactor
/// @notice Contract for querying the liquidation health factor of an Aave account.
contract AaveHealthFactor is IAaveHealthFactor {
    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IAaveHealthFactor
    function getHealthFactor(address pool, address account) public view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = IAaveHealthPool(pool).getUserAccountData(account);
    }
}
