// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Oracle} from "../Oracle.sol";
import {IAggregatorV3} from "../libraries/ChainlinkPriceFeed.sol";

/// @notice Returns Securitize HINC's USD NAV per share, scaled to 18 decimals.
contract HINC_Oracle is Oracle {
    address public constant NAV_FEED = 0xbD284A0338ba4bd09Ec13Cd18Fd275442456C6d6;
    uint256 public constant MAX_PRICE_AGE = 48 hours;

    constructor() Oracle(243.505_930_25 ether, 3409.083_023_5 ether) {}

    function _getPrice() internal view override returns (uint256) {
        IAggregatorV3 feed = IAggregatorV3(NAV_FEED);
        if (feed.decimals() != 8) revert InvalidPrice();
        (uint80 round, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        if (
            round == 0 || answeredInRound != round || answer <= 0 || startedAt == 0 || startedAt > updatedAt
                || updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_PRICE_AGE
        ) revert InvalidPrice();
        return uint256(answer) * 1e10;
    }
}
