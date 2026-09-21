// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    IEulerHealthFactor
} from "../../../../interfaces/merkle-adapter/automations/health-factors/IEulerHealthFactor.sol";
import {
    IEulerHealthVault
} from "../../../../interfaces/merkle-adapter/automations/health-factors/IEulerHealthVault.sol";

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

/// @title EulerHealthFactor
/// @notice Contract for querying liquidation health in the Euler liability vault.
contract EulerHealthFactor is IEulerHealthFactor {
    using Math for uint256;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IEulerHealthFactor
    function getHealthFactor(address vault, address account) public view returns (uint256 healthFactor) {
        (uint256 collateralValue, uint256 liabilityValue) = IEulerHealthVault(vault).accountLiquidity(account, true);
        return liabilityValue == 0 ? type(uint256).max : collateralValue.fullMulDiv(1e18, liabilityValue);
    }
}
