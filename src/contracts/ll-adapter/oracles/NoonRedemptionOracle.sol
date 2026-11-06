// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Oracle} from "./Oracle.sol";

import {INoonRedeemHandler} from "../../../interfaces/ll-adapter/noon/INoonRedeemHandler.sol";
import {INoonRedemptionOracle} from "../../../interfaces/ll-adapter/oracles/INoonRedemptionOracle.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title NoonRedemptionOracle
/// @notice Quotes sUSN -> USN -> collateral using the native redemption rate.
contract NoonRedemptionOracle is Oracle, INoonRedemptionOracle {
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc INoonRedemptionOracle
    address public immutable TOKEN_TO_REDEEM;

    /// @inheritdoc INoonRedemptionOracle
    address public immutable REDEEM_HANDLER;

    /// @inheritdoc INoonRedemptionOracle
    address public immutable QUOTE_TOKEN;

    uint256 internal immutable _tokenUnit;
    uint256 internal immutable _quoteUnit;

    /* CONSTRUCTOR */

    /// @notice Creates a bounded sUSN redemption quote in the selected collateral.
    constructor(
        uint256 newMinPrice,
        uint256 newMaxPrice,
        address newTokenToRedeem,
        address newRedeemHandler,
        address newQuoteToken
    ) Oracle(newMinPrice, newMaxPrice) {
        if (IERC4626(newTokenToRedeem).asset() != INoonRedeemHandler(newRedeemHandler).usnToken()) revert InvalidUnderlying();
        TOKEN_TO_REDEEM = newTokenToRedeem;
        REDEEM_HANDLER = newRedeemHandler;
        QUOTE_TOKEN = newQuoteToken;
        _tokenUnit = 10 ** IERC20Metadata(newTokenToRedeem).decimals();
        _quoteUnit = 10 ** IERC20Metadata(newQuoteToken).decimals();
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        return INoonRedeemHandler(REDEEM_HANDLER)
            .calculateCollateralAmount(QUOTE_TOKEN, IERC4626(TOKEN_TO_REDEEM).convertToAssets(_tokenUnit))
            .mulDiv(1e18, _quoteUnit);
    }
}
