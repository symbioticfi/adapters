// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title AccountPause
/// @notice Dummy Account implementation used for an emergency-freeze contracts proposal.
/// @dev Account business calls unconditionally revert while migration functionality remains available for recovery.
contract AccountPause is MigratableEntity {
    constructor(address factory) MigratableEntity(factory) {}

    fallback() external payable {
        revert();
    }
}
