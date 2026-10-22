// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployRealisticTestnetScript} from "./DeployRealisticTestnet.s.sol";
import {TestnetPhaseScript} from "./base/TestnetPhase.s.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IVaultV2} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";
import {IUniversalDelegator} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";

/// @title SyncMerkleTestnetScript
/// @notice Validates accepted CRE snapshots and sweeps covered liquidity through the delegator.
contract SyncMerkleTestnetScript is TestnetPhaseScript {
    error ReportUnavailable();

    function run() public {
        runBase(load());
    }

    /// @notice Loads only the identities needed to settle covered liquidity from the human-readable manifest.
    function load() public view override returns (DeployRealisticTestnetScript.Deployment memory deployed) {
        string memory json =
            vm.readFile(vm.envOr("TESTNET_MANIFEST", string("script/deploy/testnet/manifests/realistic.json")));
        deployed.chainId = vm.parseJsonUint(json, ".chainId");
        deployed.startBlock = vm.parseJsonUint(json, ".startBlock");
        deployed.owner = vm.parseJsonAddress(json, ".owner");
        deployed.vaultFactory = vm.parseJsonAddress(json, ".vaultFactory");
        deployed.chainlinkRegistry = vm.parseJsonAddress(json, ".chainlinkRegistry");
        deployed.forwarder = vm.parseJsonAddress(json, ".forwarder");
        address[] memory adapters = vm.parseJsonAddressArray(json, ".merkleAdapters");
        address[] memory registries = vm.parseJsonAddressArray(json, ".workflowRegistries");
        if (
            vm.parseJsonUint(json, ".schemaVersion") != 2 || deployed.chainId != block.chainid
                || deployed.owner == address(0) || deployed.vaultFactory.code.length == 0 || adapters.length == 0
                || adapters.length != registries.length
        ) revert InvalidManifest();
        deployed.markets = new DeployRealisticTestnetScript.Market[](adapters.length);
        for (uint256 i; i < adapters.length; ++i) {
            deployed.markets[i].merkle.adapter = adapters[i];
            deployed.markets[i].merkle.workflowRegistry = registries[i];
        }
    }

    function runBase(DeployRealisticTestnetScript.Deployment memory deployed) public {
        if (
            deployed.chainId != block.chainid || deployed.owner == address(0) || deployed.markets.length == 0
                || (block.chainid == 11_155_111
                    && (deployed.forwarder != 0xF8344CFd5c43616a4366C34E3EEE75af79a74482
                        || deployed.forwarder.code.length == 0
                        || deployed.chainlinkRegistry.code.length == 0))
        ) revert InvalidManifest();
        // Check every accepted snapshot before creating the first settlement transaction.
        for (uint256 i; i < deployed.markets.length; ++i) {
            address adapter = deployed.markets[i].merkle.adapter;
            address oracle = IMerkleAdapter(adapter).oracle();
            address registry = deployed.markets[i].merkle.workflowRegistry;
            (uint48 snapshot,) = ICREOracle(oracle).latestSnapshot();
            if (
                snapshot == 0 || snapshot >= block.number || ICREOracle(oracle).adapter() != adapter
                    || ICREOracle(oracle).WORKFLOW_REGISTRY() != registry
                    || ICREOracle(oracle).FORWARDER() != deployed.forwarder
                    || ICREWorkflowRegistry(registry).CHAINLINK_WORKFLOW_REGISTRY() != deployed.chainlinkRegistry
                    || ICREWorkflowRegistry(registry).workflowId(oracle) == bytes32(0)
            ) revert ReportUnavailable();
        }
        _start(deployed.owner);
        for (uint256 i; i < deployed.markets.length; ++i) {
            address adapter = deployed.markets[i].merkle.adapter;
            IUniversalDelegator(IVaultV2(IMerkleAdapter(adapter).vault()).delegator()).sweepPending();
        }
        _stop();
    }
}
