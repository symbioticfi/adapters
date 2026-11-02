// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";

// Keep explicit budgets below Osaka's 16,777,216 transaction gas cap.
uint256 constant ACTIVITY_TRANSACTION_GAS_LIMIT = 16_000_000;

/**
 * @title ActivityContext
 * @notice Native fixture identities and bounded funding for one catalog integration's activity.
 */
struct ActivityContext {
    address owner;
    address asset;
    address token;
    address endpoint;
    address feed;
    address oracle;
    address account;
    uint256 profile;
    uint8 kind;
    uint8 variant;
    uint256 assets;
    uint256 seed;
    uint256 cursor;
}

/// @title ActivityPhaseScript
/// @notice Shares keystore broadcaster selection with unit-test execution of fixture activity.
abstract contract ActivityPhaseScript is Script {
    function _start(address owner, bool broadcast) internal {
        if (broadcast) vm.startBroadcast(owner);
        else vm.startPrank(owner, owner);
    }

    function _stop(bool broadcast) internal {
        if (broadcast) vm.stopBroadcast();
        else vm.stopPrank();
    }
}
