// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAssetRateLimits} from "./IAssetRateLimits.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/// @title ILiquidLaneAction
/// @notice Interface for Merkle-authorized Liquid Lane configuration and pricing.
interface ILiquidLaneAction is IMigratableEntity, IAssetRateLimits {
    /// @notice Reverts when the configured adapter is zero.
    error InvalidAdapter();

    /// @notice Reverts when a function is not called by the bound adapter.
    error InvalidCaller();

    /// @notice Reverts when initialization data includes anything other than the adapter address.
    error InvalidInitializationData();

    /// @notice Reverts when the implementation input asset is zero or a migration changes it.
    error InvalidInputAsset();

    /// @notice Reverts when migration data is not supported by this implementation.
    error InvalidMigrationData();

    /// @notice Reverts when an RWA token is not valid for the requested operation.
    error InvalidTokenToRedeem();

    /// @notice Reverts when the requested RWA amount exceeds action inventory.
    error InsufficientRwaBalance();

    /// @notice Reverts when the requested input-asset amount exceeds the oracle quote.
    error InvalidSwapRate();

    /// @notice Direct RWA inventory swap payload.
    /// @param recipient Recipient of the input-asset output.
    /// @param tokenIn RWA token used to price the swap.
    /// @param amountIn RWA amount used to price the swap.
    /// @param amountOut Input-asset amount transferred to the recipient.
    struct Swap {
        address recipient;
        address tokenIn;
        uint256 amountIn;
        uint256 amountOut;
    }

    /// @notice Emitted when input assets are exchanged against available RWA inventory.
    /// @param swap_ Executed swap payload.
    event DoSwap(Swap swap_);

    /// @notice Returns the only adapter authorized to use this action.
    /// @return adapter_ Adapter address.
    function adapter() external view returns (address adapter_);

    /// @notice Returns the token paid by the adapter during swaps.
    /// @return asset Input asset address.
    function inputAsset() external view returns (address asset);

    /// @notice Returns the implementation's fixed oracle for an RWA token, or zero when unsupported.
    /// @dev Override using constants or constructor immutables. Prices are in inputAsset() at 1e18 precision.
    ///      Return zero for the zero address and the input asset. No per-proxy asset or oracle configuration exists.
    /// @param tokenToRedeem RWA token address.
    /// @return oracle_ Oracle address, shared by all proxies using this implementation.
    function oracle(address tokenToRedeem) external view returns (address oracle_);

    /// @notice Quotes an RWA amount in the input asset using its oracle.
    /// @param tokenToRedeem RWA token address.
    /// @param amountIn RWA token amount.
    /// @return amountOut Input-asset amount.
    function getAmountOut(address tokenToRedeem, uint256 amountIn) external view returns (uint256 amountOut);

    /// @notice Transfers input assets from the adapter to a recipient against available RWA inventory.
    /// @param swap_ Swap payload.
    function swap(Swap calldata swap_) external;
}
