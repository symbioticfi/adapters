// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.36;

import {IOracle} from "../../../interfaces/ll-adapter/IOracle.sol";

/// @title Oracle
/// @notice Base oracle contract with immutable price bounds.
abstract contract Oracle is IOracle {
    /* IMMUTABLES */

    /// @notice Minimum valid price.
    uint256 public immutable MIN_PRICE;

    /// @notice Maximum valid price.
    uint256 public immutable MAX_PRICE;

    /* CONSTRUCTOR */

    /// @dev Creates the bounded oracle.
    constructor(uint256 newMinPrice, uint256 newMaxPrice) {
        if (newMinPrice == 0 || newMinPrice >= newMaxPrice) revert InvalidPriceRange();

        MIN_PRICE = newMinPrice;
        MAX_PRICE = newMaxPrice;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IOracle
    function getPrice() public view virtual returns (uint256 price) {
        price = _getPrice();
        if (price < MIN_PRICE || price > MAX_PRICE) revert InvalidPrice();
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Returns the raw source price before range validation.
    function _getPrice() internal view virtual returns (uint256);
}
