// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Oracle} from "./Oracle.sol";

import {IOpenEdenTBILLOracle} from "../../../../interfaces/merkle-adapter/connectors/oracles/IOpenEdenTBILLOracle.sol";
import {IOpenEdenTBILL} from "../../../../interfaces/merkle-adapter/connectors/openeden/IOpenEdenTBILL.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title OpenEdenTBILLOracle
/// @notice Returns the TBILL NAV per token in underlying units, scaled to 1e18.
contract OpenEdenTBILLOracle is Oracle, IOpenEdenTBILLOracle {
    /* IMMUTABLES */

    /// @inheritdoc IOpenEdenTBILLOracle
    address public immutable TOKEN_TO_REDEEM;

    uint256 internal immutable _tokenUnit;
    uint256 internal immutable _assetUnit;

    /* CONSTRUCTOR */

    /// @notice Creates the bounded TBILL conversion oracle.
    constructor(uint256 newMinPrice, uint256 newMaxPrice, address newTokenToRedeem) Oracle(newMinPrice, newMaxPrice) {
        TOKEN_TO_REDEEM = newTokenToRedeem;
        _tokenUnit = 10 ** IERC20Metadata(newTokenToRedeem).decimals();
        _assetUnit = 10 ** IERC20Metadata(IOpenEdenTBILL(newTokenToRedeem).underlying()).decimals();
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        return IOpenEdenTBILL(TOKEN_TO_REDEEM).previewRedeem(_tokenUnit) * 1e18 / _assetUnit;
    }
}
