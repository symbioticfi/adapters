// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {Oracle} from "./Oracle.sol";

import {IMakinaMachine} from "../../../interfaces/ll-adapter/makina/IMakinaMachine.sol";
import {IMakinaOracle} from "../../../interfaces/ll-adapter/oracles/IMakinaOracle.sol";
import {IMakinaSharePriceOracle} from "../../../interfaces/ll-adapter/makina/IMakinaSharePriceOracle.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MakinaOracle
/// @notice Oracle contract returning a Makina Machine share price in `1e18` precision.
contract MakinaOracle is Oracle, IMakinaOracle {
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IMakinaOracle
    address public immutable SHARE_PRICE_ORACLE;

    /// @inheritdoc IMakinaOracle
    address public immutable MACHINE;

    /// @inheritdoc IMakinaOracle
    uint48 public immutable STALENESS_DURATION;

    /// @dev Source oracle unit.
    uint256 internal immutable _priceUnit;

    /* CONSTRUCTOR */

    /// @notice Creates the Makina share-price oracle adapter.
    constructor(
        uint256 newMinPrice,
        uint256 newMaxPrice,
        address newSharePriceOracle,
        address newMachine,
        uint48 newStalenessDuration
    ) Oracle(newMinPrice, newMaxPrice) {
        SHARE_PRICE_ORACLE = newSharePriceOracle;
        MACHINE = newMachine;
        STALENESS_DURATION = newStalenessDuration;
        _priceUnit = 10 ** IMakinaSharePriceOracle(newSharePriceOracle).decimals();
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        uint256 updatedAt = IMakinaMachine(MACHINE).lastGlobalAccountingTime();
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > STALENESS_DURATION) {
            return 0;
        }
        return IMakinaSharePriceOracle(SHARE_PRICE_ORACLE).getSharePrice().mulDiv(1e18, _priceUnit);
    }
}
