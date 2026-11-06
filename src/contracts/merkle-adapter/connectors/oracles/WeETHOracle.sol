// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Oracle} from "./Oracle.sol";

import {IWeETHOracle} from "../../../../interfaces/merkle-adapter/connectors/oracles/IWeETHOracle.sol";
import {IWeETH} from "../../../../interfaces/ll-adapter/etherfi/IWeETH.sol";

/// @title WeETHOracle
/// @notice Oracle contract returning the native weETH-to-eETH rate in `1e18` precision.
contract WeETHOracle is Oracle, IWeETHOracle {
    /* IMMUTABLES */

    /// @inheritdoc IWeETHOracle
    address public immutable WEETH;

    /* CONSTRUCTOR */

    /// @notice Creates the native weETH rate oracle.
    constructor(uint256 newMinPrice, uint256 newMaxPrice, address newWeETH) Oracle(newMinPrice, newMaxPrice) {
        WEETH = newWeETH;
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        return IWeETH(WEETH).getEETHByWeETH(1e18);
    }
}
