// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {Oracle} from "./Oracle.sol";

import {IOpenEdenExpress} from "../../../interfaces/ll-adapter/openeden/IOpenEdenExpress.sol";
import {IOpenEdenOracle} from "../../../interfaces/ll-adapter/oracles/IOpenEdenOracle.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OpenEdenOracle
/// @notice Oracle contract returning the OpenEden HYBOND net redemption price in `1e18` precision.
contract OpenEdenOracle is Oracle, IOpenEdenOracle {
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IOpenEdenOracle
    address public immutable TOKEN_TO_REDEEM;

    /// @inheritdoc IOpenEdenOracle
    address public immutable EXPRESS;

    /// @dev Token-to-redeem unit.
    uint256 internal immutable _TOKEN_UNIT;

    /// @dev Redemption token unit.
    uint256 internal immutable _REDEMPTION_TOKEN_UNIT;

    /* CONSTRUCTOR */

    /// @notice Creates the OpenEden HYBOND redemption-price oracle.
    constructor(uint256 newMinPrice, uint256 newMaxPrice, address newTokenToRedeem, address newExpress)
        Oracle(newMinPrice, newMaxPrice)
    {
        TOKEN_TO_REDEEM = newTokenToRedeem;
        EXPRESS = newExpress;
        _TOKEN_UNIT = 10 ** IERC20Metadata(newTokenToRedeem).decimals();
        _REDEMPTION_TOKEN_UNIT = 10 ** IERC20Metadata(IOpenEdenExpress(newExpress).redeemAsset()).decimals();
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        (,, uint256 netRedemptionAssets) = IOpenEdenExpress(EXPRESS).previewRedeem(_TOKEN_UNIT);
        return netRedemptionAssets.mulDiv(1e18, _REDEMPTION_TOKEN_UNIT);
    }
}
