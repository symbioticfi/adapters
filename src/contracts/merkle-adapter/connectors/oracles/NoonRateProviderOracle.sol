// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Oracle} from "./Oracle.sol";

import {
    INoonRateProviderOracle
} from "../../../../interfaces/merkle-adapter/connectors/oracles/INoonRateProviderOracle.sol";
import {INoonRateProvider} from "../../../../interfaces/ll-adapter/noon/INoonRateProvider.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title NoonRateProviderOracle
/// @notice Oracle contract returning a Noon rate-provider quote in `1e18` precision.
contract NoonRateProviderOracle is Oracle, INoonRateProviderOracle {
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc INoonRateProviderOracle
    address public immutable RATE_PROVIDER;

    /// @inheritdoc INoonRateProviderOracle
    address public immutable TOKEN_TO_REDEEM;

    /// @inheritdoc INoonRateProviderOracle
    address public immutable QUOTE_TOKEN;

    /// @dev Base-token unit.
    uint256 internal immutable _baseUnit;

    /// @dev Quote-token unit.
    uint256 internal immutable _quoteUnit;

    /* CONSTRUCTOR */

    /// @notice Creates the bounded Noon oracle.
    constructor(uint256 newMinPrice, uint256 newMaxPrice, address newRateProvider, address newTokenToRedeem)
        Oracle(newMinPrice, newMaxPrice)
    {
        RATE_PROVIDER = newRateProvider;
        TOKEN_TO_REDEEM = newTokenToRedeem;
        QUOTE_TOKEN = IERC4626(newTokenToRedeem).asset();
        _baseUnit = 10 ** IERC20Metadata(newTokenToRedeem).decimals();
        _quoteUnit = 10 ** IERC20Metadata(QUOTE_TOKEN).decimals();
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        return
            INoonRateProvider(RATE_PROVIDER).getQuote(_baseUnit, TOKEN_TO_REDEEM, QUOTE_TOKEN).mulDiv(1e18, _quoteUnit);
    }
}
