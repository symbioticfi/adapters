// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IChainlinkPriceFeed
 * @notice Interface defining round data for Chainlink price queries.
 */
interface IChainlinkPriceFeed {
    /* STRUCTS */

    /**
     * @notice Data for an aggregator round.
     * @param roundId Round identifier combining the phase and original round identifier.
     * @param answer Reported price, normalized when returned by a price query.
     * @param startedAt Round start timestamp (deprecated).
     * @param updatedAt Timestamp when the answer was updated.
     * @param answeredInRound Round in which the answer was computed (deprecated).
     */
    struct RoundData {
        uint80 roundId;
        uint256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }
}
