// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IThreeFRequestFactory
 * @notice Interface for requests created by the native 3F factory.
 */
interface IThreeFRequestFactory {
    /**
     * @notice Returns whether the factory created this request.
     */
    function isRequest(address request) external view returns (bool);
}
