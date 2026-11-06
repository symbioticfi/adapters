// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Oracle} from "./Oracle.sol";

import {IFigureOracle} from "../../../../interfaces/merkle-adapter/connectors/oracles/IFigureOracle.sol";
import {IFigureYieldVault} from "../../../../interfaces/ll-adapter/figure/IFigureYieldVault.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FigureOracle
/// @notice Oracle contract returning the Figure/Hastra redemption price in `1e18` precision.
contract FigureOracle is Oracle, IFigureOracle {
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IFigureOracle
    address public immutable TOKEN_TO_REDEEM;

    /// @inheritdoc IFigureOracle
    address public immutable ASYNC_REDEEM_VAULT;

    /// @dev Token-to-redeem unit.
    uint256 internal immutable _TOKEN_UNIT;

    /// @dev Redemption token unit.
    uint256 internal immutable _REDEMPTION_TOKEN_UNIT;

    /* CONSTRUCTOR */

    /// @notice Creates the Figure/Hastra redemption-price oracle.
    constructor(uint256 newMinPrice, uint256 newMaxPrice, address newTokenToRedeem) Oracle(newMinPrice, newMaxPrice) {
        TOKEN_TO_REDEEM = newTokenToRedeem;
        ASYNC_REDEEM_VAULT = IERC4626(newTokenToRedeem).asset();
        _TOKEN_UNIT = 10 ** IERC20Metadata(newTokenToRedeem).decimals();
        _REDEMPTION_TOKEN_UNIT = 10 ** IERC20Metadata(IFigureYieldVault(ASYNC_REDEEM_VAULT).asset()).decimals();
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        return IFigureYieldVault(ASYNC_REDEEM_VAULT)
            .convertToAssets(IERC4626(TOKEN_TO_REDEEM).convertToAssets(_TOKEN_UNIT))
            .mulDiv(1e18, _REDEMPTION_TOKEN_UNIT);
    }
}
