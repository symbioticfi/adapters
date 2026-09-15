// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IOracleRegistry
/// @notice Interface for the Liquid Lane price-oracle factory registry.
interface IOracleRegistry {
    /// @notice Reverts when a factory is already configured for an asset and RWA pair.
    error OracleFactoryAlreadySet();

    /// @notice Emitted when an asset-specific RWA oracle factory is set.
    /// @param asset Vault asset address.
    /// @param tokenToRedeem RWA token address.
    /// @param factory Oracle factory address.
    event SetOracleFactory(address indexed asset, address indexed tokenToRedeem, address indexed factory);

    /// @notice Returns the oracle factory for an asset and RWA pair.
    /// @param asset Vault asset address.
    /// @param tokenToRedeem RWA token address.
    /// @return factory Oracle factory address.
    function oracleFactories(address asset, address tokenToRedeem) external view returns (address factory);

    /// @notice Sets the oracle factory for an asset and RWA pair.
    /// @param asset Vault asset address.
    /// @param tokenToRedeem RWA token address.
    /// @param factory Oracle factory address.
    function setOracleFactory(address asset, address tokenToRedeem, address factory) external;
}
