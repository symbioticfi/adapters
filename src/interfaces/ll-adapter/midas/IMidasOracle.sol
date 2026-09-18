// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle} from "../IOracle.sol";

/**
 * @title IMidasDataFeed
 * @notice Interface for Midas data feeds.
 */
interface IMidasDataFeed {
    /* FUNCTIONS */

    /**
     * @notice Returns the aggregator answer normalized to 18 decimals.
     * @return answer The fetched aggregator answer.
     */
    function getDataInBase18() external view returns (uint256 answer);

    /**
     * @notice Returns the underlying Chainlink-compatible aggregator.
     * @return aggregator The aggregator address.
     */
    function aggregator() external view returns (address aggregator);
}

/**
 * @title IMidasOracle
 * @notice Interface for Midas-backed liquidity lane token oracles.
 */
interface IMidasOracle is IOracle {
    /* FUNCTIONS */

    /**
     * @notice Returns the Midas data feed.
     * @return dataFeed The data feed address.
     */
    function DATA_FEED() external view returns (address dataFeed);
}
