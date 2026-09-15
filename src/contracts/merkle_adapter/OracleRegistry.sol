// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {IOracleRegistry} from "../../interfaces/merkle_adapter/IOracleRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title OracleRegistry
/// @notice Owned registry for asset-specific RWA price-oracle factories.
contract OracleRegistry is Ownable, IOracleRegistry {
    /// @inheritdoc IOracleRegistry
    mapping(address asset => mapping(address tokenToRedeem => address factory)) public oracleFactories;

    /// @dev Sets the initial registry owner.
    constructor(address newOwner) Ownable(newOwner) {}

    /// @inheritdoc IOracleRegistry
    function setOracleFactory(address asset, address tokenToRedeem, address factory) public onlyOwner {
        if (oracleFactories[asset][tokenToRedeem] != address(0)) {
            revert OracleFactoryAlreadySet();
        }

        oracleFactories[asset][tokenToRedeem] = factory;

        emit SetOracleFactory(asset, tokenToRedeem, factory);
    }
}
