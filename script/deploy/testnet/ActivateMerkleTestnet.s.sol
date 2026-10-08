// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {DeployRealisticTestnetScript} from "./DeployRealisticTestnet.s.sol";
import {TestnetPhaseScript} from "./base/TestnetPhase.s.sol";

import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

/// @title ActivateMerkleTestnetScript
/// @notice Links the actual Chainlink registry and performs proposal/acceptance for each testnet oracle.
contract ActivateMerkleTestnetScript is TestnetPhaseScript {
    function run() public {
        DeployRealisticTestnetScript.Deployment memory deployed = load();
        runBase(
            deployed,
            uint48(vm.envUint("TESTNET_LINK_EXPIRY")),
            vm.envBytes32("TESTNET_LINK_PROOF"),
            vm.envBytes("TESTNET_LINK_SIGNATURES", ",")
        );
    }

    function runBase(
        DeployRealisticTestnetScript.Deployment memory deployed,
        uint48 expiry,
        bytes32 proof,
        bytes[] memory signatures
    ) public {
        if (signatures.length != deployed.markets.length) revert InvalidManifest();
        ICREWorkflowRegistry.WorkflowParams memory params = ICREWorkflowRegistry.WorkflowParams({
            donFamily: "testnet",
            binaryUrl: vm.envOr("TESTNET_WORKFLOW_BINARY_URL", string("https://localhost/testnet-nav.wasm.br")),
            configUrl: vm.envOr("TESTNET_WORKFLOW_CONFIG_URL", string("https://localhost/testnet-nav.json")),
            attributes: ""
        });
        _start(deployed.owner);
        for (uint256 i; i < deployed.markets.length; ++i) {
            address registry = deployed.markets[i].merkle.workflowRegistry;
            address oracle = IMerkleAdapter(deployed.markets[i].merkle.adapter).oracle();
            CREWorkflowRegistry(registry).linkOwner(expiry, keccak256(abi.encode(proof, registry)), signatures[i]);
            bytes32 id = keccak256(abi.encode(block.chainid, oracle, deployed.startBlock));
            CREWorkflowRegistry(registry).proposeWorkflow(oracle, id, params);
            CREWorkflowRegistry(registry).acceptWorkflow(oracle, id, params);
        }
        _stop();
    }

    function linkHash(
        DeployRealisticTestnetScript.Deployment memory deployed,
        uint256 market,
        uint48 expiry,
        bytes32 proof
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                uint8(0),
                deployed.markets[market].merkle.workflowRegistry,
                block.chainid,
                deployed.chainlinkRegistry,
                "WorkflowRegistry 2.0.0",
                uint256(expiry),
                keccak256(abi.encode(proof, deployed.markets[market].merkle.workflowRegistry))
            )
        );
    }
}
