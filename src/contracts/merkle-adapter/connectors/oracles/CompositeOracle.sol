// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Oracle} from "./Oracle.sol";

import {ICompositeOracle} from "../../../../interfaces/merkle-adapter/connectors/oracles/ICompositeOracle.sol";
import {IOracle} from "../../../../interfaces/ll-adapter/IOracle.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CompositeOracle
/// @notice Prices a token in the payment asset: source * denomination price / payment price.
contract CompositeOracle is Oracle, ICompositeOracle {
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc ICompositeOracle
    address public immutable SOURCE_ORACLE;

    /// @inheritdoc ICompositeOracle
    address public immutable CONVERSION_ORACLE;

    /// @inheritdoc ICompositeOracle
    address public immutable QUOTE_ORACLE;

    /* CONSTRUCTOR */

    /// @notice Creates a bounded quote from existing 1e18-scaled oracles.
    /// @dev Zero conversion or quote addresses mean identity; the source is required.
    constructor(
        uint256 newMinPrice,
        uint256 newMaxPrice,
        address newSourceOracle,
        address newConversionOracle,
        address newQuoteOracle
    ) Oracle(newMinPrice, newMaxPrice) {
        if (newSourceOracle == address(0)) revert InvalidSource();
        SOURCE_ORACLE = newSourceOracle;
        CONVERSION_ORACLE = newConversionOracle;
        QUOTE_ORACLE = newQuoteOracle;
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256 price) {
        price = IOracle(SOURCE_ORACLE).getPrice();
        if (CONVERSION_ORACLE != address(0)) {
            price = price.mulDiv(IOracle(CONVERSION_ORACLE).getPrice(), 1e18);
        }
        if (QUOTE_ORACLE != address(0)) {
            uint256 quote = IOracle(QUOTE_ORACLE).getPrice();
            if (quote == 0) revert InvalidPrice();
            price = price.mulDiv(1e18, quote);
        }
    }
}
