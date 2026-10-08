// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {DeployMerkleAdapterScript} from "script/deploy/adapters/DeployMerkleAdapter.s.sol";

/// @title TestnetMerkleScript
/// @notice Runs the existing Merkle deployment under the same broadcaster as the from-zero scripts.
contract TestnetMerkleScript is DeployMerkleAdapterScript {
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

    function _scriptOwner() internal view override returns (address) {
        return _OWNER;
    }
}
