// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IThreeFVaultController} from "./IThreeFVaultController.sol";

/**
 * @title IThreeFRequest
 * @notice Interface for minimal interface for 3F requests.
 */
interface IThreeFRequest is IThreeFVaultController {
    /* FUNCTIONS */

    /**
     * @notice Returns the request asset.
     * @return asset Request asset.
     */
    function asset() external view returns (address asset);

    /**
     * @notice Advances the caller's offer nonce.
     * @param newNonce New nonce value.
     */
    function setNonce(uint256 newNonce) external;
}
