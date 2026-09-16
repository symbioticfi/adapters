// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {IOracleRegistry} from "../../interfaces/merkle_adapter/IOracleRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title OracleRegistry
/// @notice Owned registry of RWA price oracles approved for individual Liquid Lane actions.
contract OracleRegistry is Ownable, IOracleRegistry {
    /// @inheritdoc IOracleRegistry
    mapping(address adapter => mapping(address tokenToRedeem => address oracle)) public oracles;

    /// @dev Sets the initial registry owner.
    constructor(address newOwner) Ownable(newOwner) {}

    /// @inheritdoc IOracleRegistry
    function setOracle(address adapter, address tokenToRedeem, address oracle) public onlyOwner {
        oracles[adapter][tokenToRedeem] = oracle;

        emit SetOracle(adapter, tokenToRedeem, oracle);
    }
}
