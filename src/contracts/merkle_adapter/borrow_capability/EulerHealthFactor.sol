// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {IEulerHealthFactor} from "../../../interfaces/merkle_adapter/borrow_capability/IEulerHealthFactor.sol";
import {IEulerHealthVault} from "../../../interfaces/merkle_adapter/borrow_capability/IEulerHealthVault.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title EulerHealthFactor
/// @notice Contract for querying liquidation health in the Euler liability vault.
contract EulerHealthFactor is IEulerHealthFactor {
    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IEulerHealthFactor
    function getHealthFactor(address vault, address account) public view returns (uint256 healthFactor) {
        (uint256 collateralValue, uint256 liabilityValue) = IEulerHealthVault(vault).accountLiquidity(account, true);
        return liabilityValue == 0 ? type(uint256).max : Math.mulDiv(collateralValue, 1e18, liabilityValue);
    }
}
