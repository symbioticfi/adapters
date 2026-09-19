// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    IEulerHealthFactor
} from "../../../../interfaces/merkle-adapter/capabilities/borrow-capability/IEulerHealthFactor.sol";
import {
    IEulerHealthVault
} from "../../../../interfaces/merkle-adapter/capabilities/borrow-capability/IEulerHealthVault.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title EulerHealthFactor
/// @notice Contract for querying liquidation health in the Euler liability vault.
contract EulerHealthFactor is IEulerHealthFactor {
    using Math for uint256;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IEulerHealthFactor
    function getHealthFactor(address vault, address account) public view returns (uint256 healthFactor) {
        (uint256 collateralValue, uint256 liabilityValue) = IEulerHealthVault(vault).accountLiquidity(account, true);
        return liabilityValue == 0 ? type(uint256).max : collateralValue.mulDiv(1e18, liabilityValue);
    }
}
