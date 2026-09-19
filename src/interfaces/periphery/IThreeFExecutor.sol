// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IExecutor} from "./IExecutor.sol";

/**
 * @title IThreeFExecutor
 * @notice Interface for funding and minting 3F positions owned by a Merkle adapter.
 */
interface IThreeFExecutor is IExecutor {
    /* ERRORS */

    /// @notice Raised when the live authorization differs from the exact nonzero principal requested.
    error InvalidMintAuthorization();

    /// @notice Raised when the mint deadline has passed.
    error MintDeadlineExpired();

    /// @notice Raised when the configured native factory did not create the request.
    error NotRequest();

    /* EVENTS */

    /**
     * @notice Emitted when the adapter funds and mints a request with exactly the specified principal.
     */
    event Mint(address indexed request, uint256 amount);

    /* FUNCTIONS */

    /// @notice Returns the native factory used to validate request addresses.
    function requestsFactory() external view returns (address);
    /// @notice Returns this executor's separately owned funding budget and minimum yield configuration.
    function policy() external view returns (address);

    /**
     * @notice Funds and mints a native 3F request through the adapter's approved calls.
     * @dev Caller-only. The amount is exact, not a partial fill: a differing live authorization reverts atomically.
     * Factory membership, deadline, local yield and period budget are checked before funding.
     * The mint uses GuardedCallsCapability only to dispatch a Merkle-authorized native request call.
     * Direct adapter execution has no executor policy. Request positions are read from native PT/YT state.
     * @param request Factory-created 3F request receiving the adapter's principal.
     * @param amount Exact principal to prepare and spend.
     * @param minYield Minimum acceptable yield-token amount.
     * @param deadline Last timestamp at which the mint is allowed.
     * @param execution Current funding calls and authorization for the request approval and native mint wrapper.
     */
    function mint(address request, uint128 amount, uint128 minYield, uint256 deadline, Execution calldata execution)
        external;
}
