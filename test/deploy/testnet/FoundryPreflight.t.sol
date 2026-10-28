// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {ValidateRealisticTestnetScript} from "script/deploy/testnet/ValidateRealisticTestnet.s.sol";

contract FoundryPreflightTest is Test {
    function test_PublicDeploymentRejectsUnsupportedLocalChainBeforeBacking() public {
        vm.chainId(1337);
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        string memory path = "script/deploy/testnet/manifests/unsupported-chain-test.json";
        if (vm.exists(path)) vm.removeFile(path);
        vm.setEnv("TESTNET_MANIFEST", path);
        address script = deployCode("DeployRealisticTestnet.s.sol:DeployRealisticTestnetScript");
        vm.expectRevert(bytes4(keccak256("InvalidConfiguration()")));
        DeployRealisticTestnetScript(script).run();
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
    }

    function test_DeployChecksSeedBackingBeforeExternalInfrastructure() public {
        vm.chainId(11_155_111);
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        string memory previousOwner = vm.envOr("TESTNET_OWNER", string(""));
        string memory previousBudget = vm.envOr("TESTNET_SEED_ASSETS", string(""));
        string memory path = "script/deploy/testnet/manifests/backing-test.json";
        if (vm.exists(path)) vm.removeFile(path);
        vm.setEnv("TESTNET_MANIFEST", path);
        vm.setEnv("TESTNET_OWNER", vm.toString(address(0xBEEF)));
        vm.setEnv("TESTNET_SEED_ASSETS", "100000");
        address script = deployCode("DeployRealisticTestnet.s.sol:DeployRealisticTestnetScript");
        vm.expectRevert(bytes4(keccak256("InsufficientBacking()")));
        DeployRealisticTestnetScript(script).run();
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
        vm.setEnv("TESTNET_OWNER", previousOwner);
        vm.setEnv("TESTNET_SEED_ASSETS", previousBudget);
    }

    function test_ValidateRejectsChangedPinsBeforeReadingContractAddresses() public {
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        string memory path = "script/deploy/testnet/manifests/validate-pins-test.json";
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":',
                vm.toString(block.chainid),
                ',"upstreamPins":"0x0000000000000000000000000000000000000000000000000000000000000001"}'
            )
        );
        vm.setEnv("TESTNET_MANIFEST", path);
        address script = deployCode("ValidateRealisticTestnet.s.sol:ValidateRealisticTestnetScript");
        vm.expectRevert(bytes4(keccak256("InvalidDeployment()")));
        ValidateRealisticTestnetScript(script).run();
        vm.removeFile(path);
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
    }
}
