// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {DeployMerkleAdapterScript} from "script/deploy/adapters/DeployMerkleAdapter.s.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {SepoliaCRE} from "../protocols/SepoliaCRE.sol";

/// @title TestnetMerkleScript
/// @notice Runs the existing Merkle deployment under the same broadcaster as the from-zero scripts.
contract TestnetMerkleScript is DeployMerkleAdapterScript {
    address internal immutable _OWNER;
    bool internal immutable _BROADCAST;

    constructor(address newOwner, bool broadcast) {
        _OWNER = newOwner;
        _BROADCAST = broadcast;
    }

    function deployCore(Config memory config) public returns (Deployment memory deployed) {
        _startBroadcast();
        deployed = _deployCore(config, config.provider);
        _stopBroadcast();
    }

    function runBase(Config memory config, Deployment memory core) public returns (Deployment memory deployed) {
        if (core.adapterFactory == address(0)) return runBase(config);
        _startBroadcast();
        deployed = core;
        deployed.adapter = _createAdapter(config, deployed);
        _stopBroadcast();
        _assertDeployment(
            config, deployed, IMerkleAdapter(deployed.adapter).account(), IMerkleAdapter(deployed.adapter).oracle()
        );
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

    function _deployWorkflowRegistry(Config memory config, address owner) internal override returns (address) {
        if (block.chainid == 11_155_111) return SepoliaCRE.deploy(owner, config.chainlinkWorkflowRegistry);
        return super._deployWorkflowRegistry(config, owner);
    }
}
