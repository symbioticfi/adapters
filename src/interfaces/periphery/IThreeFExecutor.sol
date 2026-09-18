// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IExecutor} from "./IExecutor.sol";

/**
 * @title IThreeFExecutor
 * @notice Interface for funding and minting 3F positions owned by a Merkle adapter.
 */
interface IThreeFExecutor is IExecutor {
    /* EVENTS */

    /**
     * @notice Emitted when the adapter funds and mints a request with exactly the specified principal.
     */
    event Mint(address indexed request, uint256 amount);

    /* FUNCTIONS */

    /**
     * @notice Funds and mints a 3F request through the adapter's ThreeFCapability.
     * @dev Caller-only. The amount is exact, not a partial fill: a differing live authorization reverts atomically.
     * The capability validates the request, yield, deadline and funding budget and records the adapter's position.
     * @param request Approved 3F request receiving the adapter's principal.
     * @param amount Exact principal to prepare and spend.
     * @param minYield Minimum acceptable yield-token amount.
     * @param deadline Last timestamp at which the mint is allowed.
     * @param execution Current funding calls and authorization for the request approval and capability mint.
     */
    function mint(address request, uint128 amount, uint128 minYield, uint256 deadline, Execution calldata execution)
        external;
}
