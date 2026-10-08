// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {DeployCoreBaseScript} from "@symbioticfi/core/script/deploy/base/DeployCoreBase.s.sol";
import {DeployV2BaseScript} from "@symbioticfi/core/script/deploy/base/DeployV2Base.s.sol";
import {SymbioticCoreConstants} from "@symbioticfi/core/test/integration/SymbioticCoreConstants.sol";

/// @title TestnetCoreScript
/// @notice Extends the existing core deployment with explicit broadcaster/prank selection.
contract TestnetCoreScript is DeployCoreBaseScript {
    address internal immutable _OWNER;
    bool internal immutable _BROADCAST;

    constructor(address newOwner, bool broadcast) {
        _OWNER = newOwner;
        _BROADCAST = broadcast;
    }

    function _startBroadcast() internal override {
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER, _OWNER);
    }

    function _stopBroadcast() internal override {
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
    }
}

/// @title TestnetV2Script
/// @notice Extends the existing V2 deployment using freshly deployed core addresses.
contract TestnetV2Script is DeployV2BaseScript {
    address internal immutable _OWNER;
    bool internal immutable _BROADCAST;
    SymbioticCoreConstants.Core internal _deployedCore;

    constructor(address newOwner, bool broadcast, SymbioticCoreConstants.Core memory core) {
        _OWNER = newOwner;
        _BROADCAST = broadcast;
        _deployedCore = core;
    }

    function _startBroadcast() internal override {
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER, _OWNER);
    }

    function _stopBroadcast() internal override {
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
    }

    function _scriptOwner() internal view override returns (address) {
        return _OWNER;
    }

    function _core() internal view override returns (SymbioticCoreConstants.Core memory) {
        return _deployedCore;
    }
}
