// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAdapter} from "./IAdapter.sol";

/**
 * @title IMorphoVaultV2Adapter
 * @notice Interface for the Morpho Vault V2 adapter.
 */
interface IMorphoVaultV2Adapter is IAdapter {
    /* ERRORS */

    /**
     * @notice Raised when the provided amount is insufficient for the requested operation.
     */
    error InsufficientAmount();

    /**
     * @notice Raised when the provided Morpho vault does not match the vault asset.
     */
    error InvalidMorphoVault();

    /**
     * @notice Raised when the deposit helper is called directly instead of through the adapter self-call.
     */
    error NotSelf();

    /* STRUCTS */

    /**
     * @notice Initialization parameters for the Morpho Vault V2 adapter.
     * @param morphoVault Morpho vault address.
     * @param converters Initial converters exempt from the prepared-request delay.
     */
    struct InitParams {
        address morphoVault;
        address[] converters;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the adapter is initialized.
     * @param morphoVault Morpho vault address.
     */
    event Initialize(address indexed morphoVault);

    /* FUNCTIONS */

    /**
     * @notice Returns the configured Morpho vault for a vault.
     * @return Configured Morpho vault.
     */
    function morphoVault() external view returns (address);

    /**
     * @notice Returns the adapter-managed Morpho vault shares.
     * @return totalShares Adapter-managed Morpho vault shares.
     */
    function totalShares() external view returns (uint256);

    /**
     * @notice Deposits assets into the Morpho vault and rejects a zero-share result.
     * @dev Only the adapter itself may call. Allocation uses this external self-call so a failed
     *      deposit, including a zero-share result, rolls back the Morpho transfer before being caught.
     * @param amount Asset amount to deposit.
     * @return shares Morpho vault shares received.
     */
    function deposit(uint256 amount) external returns (uint256 shares);
}
