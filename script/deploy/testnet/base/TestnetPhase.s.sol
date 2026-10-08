// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployRealisticTestnetScript} from "../DeployRealisticTestnet.s.sol";

import {Script} from "forge-std/Script.sol";

/// @title TestnetPhaseScript
/// @notice Loads the exact deployment manifest and shares broadcaster selection across later phases.
abstract contract TestnetPhaseScript is Script {
    error InvalidManifest();

    function load() public view returns (DeployRealisticTestnetScript.Deployment memory deployed) {
        string memory json =
            vm.readFile(vm.envOr("TESTNET_MANIFEST", string("script/deploy/testnet/manifests/realistic.json")));
        deployed = abi.decode(vm.parseJsonBytes(json, ".deployment"), (DeployRealisticTestnetScript.Deployment));
        if (deployed.chainId != block.chainid || deployed.owner == address(0) || deployed.vaultFactory.code.length == 0)
        {
            revert InvalidManifest();
        }
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
