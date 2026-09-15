// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/// @title ILiquidLaneCapability
/// @notice Interface for Merkle-authorized Liquid Lane configuration and pricing.
interface ILiquidLaneCapability is IMigratableEntity {
    /// @notice Reverts when the configured adapter is zero.
    error InvalidAdapter();

    /// @notice Reverts when a function is not called by the bound adapter.
    error InvalidCaller();

    /// @notice Reverts when the configured input asset is zero.
    error InvalidInputAsset();

    /// @notice Reverts when migration data is not supported by this implementation.
    error InvalidMigrationData();

    /// @notice Reverts when an output asset has no registered oracle factory.
    error InvalidOracleFactory();

    /// @notice Reverts when an RWA token is not valid for the requested operation.
    error InvalidTokenToRedeem();

    /// @notice Reverts when no output assets are configured.
    error EmptyTokensToRedeem();

    /// @notice Reverts when the requested RWA amount exceeds capability inventory.
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

    /// @notice Returns the only adapter authorized to use this capability.
    /// @return adapter_ Adapter address.
    function adapter() external view returns (address adapter_);

    /// @notice Returns the token paid by the adapter during swaps.
    /// @return asset Input asset address.
    function inputAsset() external view returns (address asset);

    /// @notice Returns the registry used to resolve oracle factories.
    /// @return oracleRegistry Oracle registry address.
    function ORACLE_REGISTRY() external view returns (address oracleRegistry);

    /// @notice Returns a configured RWA token by index.
    /// @param index Token index.
    /// @return tokenToRedeem RWA token address.
    function tokensToRedeem(uint256 index) external view returns (address tokenToRedeem);

    /// @notice Returns the oracle created for an RWA token.
    /// @param tokenToRedeem RWA token address.
    /// @return oracle Oracle address.
    function oracles(address tokenToRedeem) external view returns (address oracle);

    /// @notice Returns the number of configured RWA tokens.
    /// @return count Number of configured RWA tokens.
    function getTokensToRedeemLength() external view returns (uint256 count);

    /// @notice Quotes an RWA amount in the input asset using its oracle.
    /// @param tokenToRedeem RWA token address.
    /// @param amountIn RWA token amount.
    /// @return amountOut Input-asset amount.
    function getAmountOut(address tokenToRedeem, uint256 amountIn) external view returns (uint256 amountOut);

    /// @notice Transfers input assets from the adapter to a recipient against available RWA inventory.
    /// @param swap_ Swap payload.
    function swap(Swap calldata swap_) external;
}
