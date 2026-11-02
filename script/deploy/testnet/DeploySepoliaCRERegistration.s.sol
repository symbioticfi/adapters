// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SepoliaCRE} from "./protocols/SepoliaCRE.sol";
import {OfficialCRE} from "../merkle/OfficialCRE.sol";

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deploys only the Sepolia test stand's registration authority on mainnet.
contract DeploySepoliaCRERegistrationScript is Script {
    function run() public returns (address workflowOwner) {
        require(block.chainid == 1, "registration must use mainnet");
        string memory json = vm.readFile(vm.envString("TESTNET_MANIFEST"));
        require(vm.parseJsonUint(json, ".chainId") == 11_155_111, "expected Sepolia manifest");
        address owner = vm.parseJsonAddress(json, ".owner");
        address replica = vm.parseJsonAddress(json, ".chainlinkRegistry");
        address expected = vm.parseJsonAddress(
            json, vm.keyExistsJson(json, ".workflowRegistry") ? ".workflowRegistry" : ".markets[0].workflowRegistry"
        );
        OfficialCRE.validate(1, OfficialCRE.MAINNET_REGISTRY, OfficialCRE.MAINNET_FORWARDER);
        vm.startBroadcast(owner);
        workflowOwner = SepoliaCRE.deploy(owner, replica);
        vm.stopBroadcast();
        require(workflowOwner == expected, "owner pair differs: use the identical compiler and scripts");
        console2.log("Sepolia test stand workflow owner on mainnet", workflowOwner);
        console2.log("Official mainnet Workflow Registry", OfficialCRE.MAINNET_REGISTRY);
        console2.log("Sepolia replica of the upstream Workflow Registry", replica);
    }
}
