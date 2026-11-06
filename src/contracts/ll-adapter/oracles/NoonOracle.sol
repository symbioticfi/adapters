// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Oracle} from "./Oracle.sol";

import {INoonOracle} from "../../../interfaces/ll-adapter/oracles/INoonOracle.sol";
import {INoonRedeemHandler} from "../../../interfaces/ll-adapter/noon/INoonRedeemHandler.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title NoonOracle
/// @notice Quotes sUSN -> USN -> collateral using the native redemption rate.
contract NoonOracle is Oracle, INoonOracle {
    /* IMMUTABLES */

    /// @inheritdoc INoonOracle
    address public immutable TOKEN_TO_REDEEM;

    /// @inheritdoc INoonOracle
    address public immutable REDEEM_HANDLER;

    /// @inheritdoc INoonOracle
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
        TOKEN_TO_REDEEM = newTokenToRedeem;
        REDEEM_HANDLER = newRedeemHandler;
        QUOTE_TOKEN = newQuoteToken;
        _tokenUnit = 10 ** IERC20Metadata(newTokenToRedeem).decimals();
        _quoteUnit = 10 ** IERC20Metadata(newQuoteToken).decimals();
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        return INoonRedeemHandler(REDEEM_HANDLER)
                .calculateCollateralAmount(QUOTE_TOKEN, IERC4626(TOKEN_TO_REDEEM).convertToAssets(_tokenUnit)) * 1e18
            / _quoteUnit;
    }
}
