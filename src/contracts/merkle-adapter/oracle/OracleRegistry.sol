// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IOracleRegistry} from "../../../interfaces/merkle-adapter/oracle/IOracleRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title OracleRegistry
/// @notice Owned registry contract for RWA price oracles approved for individual Liquid Lane connectors.
contract OracleRegistry is Ownable, IOracleRegistry {
    /* STATE VARIABLES */

    /// @inheritdoc IOracleRegistry
    mapping(address adapter => mapping(address tokenToRedeem => address oracle)) public oracles;

    /* CONSTRUCTOR */

    /// @dev Sets the initial registry owner.
    constructor(address newOwner) Ownable(newOwner) {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IOracleRegistry
    function setOracle(address adapter, address tokenToRedeem, address newOracle) public onlyOwner {
        oracles[adapter][tokenToRedeem] = newOracle;

        emit SetOracle(adapter, tokenToRedeem, newOracle);
    }
}
