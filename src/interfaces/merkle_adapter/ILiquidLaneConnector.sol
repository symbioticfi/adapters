// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAssetRateLimits} from "./IAssetRateLimits.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/**
 * @title ILiquidLaneConnector
 * @notice Interface for Merkle-authorized Liquid Lane configuration and pricing.
 */
interface ILiquidLaneConnector is IMigratableEntity, IAssetRateLimits {
    /* ERRORS */

    /**
     * @notice Raised when the requested RWA amount exceeds connector inventory.
     */
    error InsufficientRwaBalance();

    /**
     * @notice Raised when the configured adapter is zero.
     */
    error InvalidAdapter();

    /**
     * @notice Raised when a function is not called by the bound adapter.
     */
    error InvalidCaller();

    /**
     * @notice Raised when the configured input asset is zero.
     */
    error InvalidInputAsset();

    /**
     * @notice Raised when migration data is not supported by this implementation.
     */
    error InvalidMigrationData();

    /**
     * @notice Raised when an RWA token has no oracle approved for this connector.
     */
    error InvalidOracle();

    /**
     * @notice Raised when the requested input-asset amount exceeds the oracle quote.
     */
    error InvalidSwapRate();

    /**
     * @notice Raised when an RWA token is not valid for the requested operation.
     */
    error InvalidTokenToRedeem();

    /* STRUCTS */

    /**
     * @notice Direct RWA inventory swap payload.
     * @param recipient Recipient of the input-asset output.
     * @param tokenIn RWA token used to price the swap.
     * @param amountIn RWA amount used to price the swap.
     * @param amountOut Input-asset amount transferred to the recipient.
     */
    struct Swap {
        address recipient;
        address tokenIn;
        uint256 amountIn;
        uint256 amountOut;
    }

    /* EVENTS */

    /**
     * @notice Emitted when input assets are exchanged against available RWA inventory.
     * @param newSwap Executed swap payload.
     */
    event DoSwap(Swap newSwap);

    /**
     * @notice Emitted when an RWA token is added with the currently approved oracle.
     */
    event AddTokenToRedeem(address indexed tokenToRedeem, address indexed oracle);

    /**
     * @notice Emitted when an RWA token and its saved oracle are removed.
     */
    event RemoveTokenToRedeem(address indexed tokenToRedeem);

    /* FUNCTIONS */

    /**
     * @notice Returns the only adapter authorized to use this connector.
     * @return newAdapter Adapter address.
     */
    function adapter() external view returns (address newAdapter);

    /**
     * @notice Returns the token paid by the adapter during swaps.
     * @return asset Input asset address.
     */
    function inputAsset() external view returns (address asset);

    /**
     * @notice Returns the registry used to resolve approved oracles.
     * @return oracleRegistry Oracle registry address.
     */
    function ORACLE_REGISTRY() external view returns (address oracleRegistry);

    /**
     * @notice Returns a configured RWA token by index. Removal may change token order.
     * @param index Token index.
     * @return tokenToRedeem RWA token address.
     */
    function tokensToRedeem(uint256 index) external view returns (address tokenToRedeem);

    /**
     * @notice Returns the oracle saved when an RWA token was added.
     * @param tokenToRedeem RWA token address.
     * @return oracle Oracle address.
     */
    function oracles(address tokenToRedeem) external view returns (address oracle);

    /**
     * @notice Returns the number of configured RWA tokens.
     * @return count Number of configured RWA tokens.
     */
    function getTokensToRedeemLength() external view returns (uint256 count);

    /**
     * @notice Returns an RWA amount quoted in the input asset using its oracle.
     * @param tokenToRedeem RWA token address.
     * @param amountIn RWA token amount.
     * @return amountOut Input-asset amount.
     */
    function getAmountOut(address tokenToRedeem, uint256 amountIn) external view returns (uint256 amountOut);

    /**
     * @notice Adds an RWA token and saves OracleRegistry.oracles(address(this), tokenToRedeem).
     * @dev Only the bound adapter may call this. A nonzero approval is required; duplicates revert.
     * @param tokenToRedeem RWA token address.
     */
    function addTokenToRedeem(address tokenToRedeem) external;

    /**
     * @notice Removes an RWA token and deletes its saved oracle.
     * @dev Only the bound adapter may call this. Budget configuration and usage remain intact.
     * @param tokenToRedeem Configured RWA token address.
     */
    function removeTokenToRedeem(address tokenToRedeem) external;

    /**
     * @notice Transfers input assets from the adapter to a recipient against available RWA inventory.
     * @param newSwap Swap payload.
     */
    function swap(Swap calldata newSwap) external;
}
