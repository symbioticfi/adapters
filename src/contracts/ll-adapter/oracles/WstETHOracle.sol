// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Oracle} from "./Oracle.sol";

import {IWstETHOracle} from "../../../interfaces/ll-adapter/oracles/IWstETHOracle.sol";
import {IWstETH} from "../../../interfaces/ll-adapter/lido/IWstETH.sol";

/// @title WstETHOracle
/// @notice Oracle contract returning the native wstETH-to-stETH rate in `1e18` precision.
contract WstETHOracle is Oracle, IWstETHOracle {
    /* IMMUTABLES */

    /// @inheritdoc IWstETHOracle
    address public immutable WSTETH;

    /* CONSTRUCTOR */

    /// @notice Creates the native wstETH rate oracle.
    constructor(uint256 newMinPrice, uint256 newMaxPrice, address newWstETH) Oracle(newMinPrice, newMaxPrice) {
        WSTETH = newWstETH;
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        return IWstETH(WSTETH).getStETHByWstETH(1e18);
    }
}
