// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployRealisticTestnetScript} from "../DeployRealisticTestnet.s.sol";
import {SepoliaInfrastructure} from "../SepoliaInfrastructure.sol";

import {Script} from "forge-std/Script.sol";

/// @title TestnetPhaseScript
/// @notice Loads the exact deployment manifest and shares broadcaster selection across later phases.
abstract contract TestnetPhaseScript is Script {
    error InvalidManifest();

    function load() public view virtual returns (DeployRealisticTestnetScript.Deployment memory deployed) {
        string memory json =
            vm.readFile(vm.envOr("TESTNET_MANIFEST", string("script/deploy/testnet/manifests/realistic.json")));
        if (!vm.keyExistsJson(json, ".oracleMode") || !vm.keyExistsJson(json, ".reportPublisher")) {
            revert InvalidManifest();
        }
        deployed = abi.decode(vm.parseJsonBytes(json, ".deployment"), (DeployRealisticTestnetScript.Deployment));
        if (
            vm.parseJsonUint(json, ".schemaVersion") != 2 || deployed.chainId != block.chainid
                || deployed.chainId != vm.parseJsonUint(json, ".chainId")
                || deployed.owner != vm.parseJsonAddress(json, ".owner") || deployed.owner == address(0)
                || deployed.vaultFactory.code.length == 0 || deployed.reportPublisher == address(0)
                || keccak256(bytes(deployed.oracleMode)) != keccak256(bytes(vm.parseJsonString(json, ".oracleMode")))
                || deployed.reportPublisher != vm.parseJsonAddress(json, ".reportPublisher")
                || deployed.chainlinkRegistry != vm.parseJsonAddress(json, ".chainlinkRegistry")
                || deployed.forwarder != vm.parseJsonAddress(json, ".forwarder")
        ) revert InvalidManifest();
        SepoliaInfrastructure.isSelfHosted(deployed.oracleMode);
    }

    function _broadcast() internal view virtual returns (bool) {
        return true;
    }

    function _start(address owner) internal {
        if (_broadcast()) vm.startBroadcast(owner);
        else vm.startPrank(owner, owner);
    }

    function _stop() internal {
        if (_broadcast()) vm.stopBroadcast();
        else vm.stopPrank();
    }
}
