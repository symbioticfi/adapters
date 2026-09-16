// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {ICapability} from "../../interfaces/merkle_adapter/ICapability.sol";

/// @title Capability
/// @notice Base contract for capability operations authorized by Merkle adapter self-calls.
abstract contract Capability is ICapability {
    /* MODIFIERS */

    /// @dev The adapter calls itself through manage before its fallback delegates to capability code.
    modifier onlyMyself() {
        if (address(this) != msg.sender) revert InvalidCaller();

        _;
    }
}
