// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {Oracle} from "./Oracle.sol";

import {IThreeJaneOracle} from "../../../interfaces/ll-adapter/oracles/IThreeJaneOracle.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ThreeJaneOracle
/// @notice Oracle contract returning the Three Jane USD3 redemption price in `1e18` precision.
contract ThreeJaneOracle is Oracle, IThreeJaneOracle {
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IThreeJaneOracle
    address public immutable TOKEN_TO_REDEEM;

    /// @dev USD3 token unit.
    uint256 internal immutable _TOKEN_UNIT;

    /// @dev USDC token unit.
    uint256 internal immutable _USDC_UNIT;

    /* CONSTRUCTOR */

    /// @notice Creates the Three Jane USD3 redemption-price oracle.
    constructor(uint256 newMinPrice, uint256 newMaxPrice, address newTokenToRedeem) Oracle(newMinPrice, newMaxPrice) {
        TOKEN_TO_REDEEM = newTokenToRedeem;
        _TOKEN_UNIT = 10 ** IERC20Metadata(newTokenToRedeem).decimals();
        _USDC_UNIT = 10 ** IERC20Metadata(IERC4626(newTokenToRedeem).asset()).decimals();
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        return IERC4626(TOKEN_TO_REDEEM).convertToAssets(_TOKEN_UNIT).mulDiv(1e18, _USDC_UNIT);
    }
}
