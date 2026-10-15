// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {DeployRealisticTestnetScript} from "./DeployRealisticTestnet.s.sol";
import {TestnetPhaseScript} from "./base/TestnetPhase.s.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IChainlinkWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/IChainlinkWorkflowRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title ITestnetCREActivationRegistry
 * @notice Interface for validating official Chainlink ownership-link artifacts without submitting transactions.
 */
interface ITestnetCREActivationRegistry {
    /* FUNCTIONS */

    /**
     * @notice Returns the Chainlink registry implementation version.
     */
    function typeAndVersion() external view returns (string memory);

    /**
     * @notice Validates an unused ownership proof and its authorized Chainlink signature.
     */
    function canLinkOwner(address owner, uint256 expiry, bytes32 proof, bytes calldata signature) external view;

    /**
     * @notice Returns whether an owner is already linked to the CRE organization.
     */
    function isOwnerLinked(address owner) external view returns (bool);
}

/// @title ActivateMerkleTestnetScript
/// @notice Links the actual Chainlink registry and performs proposal/acceptance for each testnet oracle.
contract ActivateMerkleTestnetScript is TestnetPhaseScript {
    using Strings for uint256;

    error InvalidActivation();
    error LocalActivationUnavailable();

    struct WorkflowArtifact {
        address oracle;
        address wrapper;
        uint48 expiry;
        bytes32 proof;
        bytes signature;
        bytes32 workflowId;
        ICREWorkflowRegistry.WorkflowParams params;
    }

    function run() public {
        DeployRealisticTestnetScript.Deployment memory deployed = load();
        if (block.chainid == 11_155_111) {
            runOfficialBase(
                deployed, readOfficialArtifacts(deployed, vm.readFile(vm.envString("TESTNET_CRE_ACTIVATION")))
            );
            return;
        }
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
        if (block.chainid == 11_155_111) revert LocalActivationUnavailable();
        if (signatures.length != deployed.markets.length) revert InvalidManifest();
        ICREWorkflowRegistry.WorkflowParams memory params = ICREWorkflowRegistry.WorkflowParams({
            tag: vm.envOr("TESTNET_WORKFLOW_TAG", string("default")),
            status: IChainlinkWorkflowRegistry.WorkflowStatus(vm.envOr("TESTNET_WORKFLOW_STATUS", uint256(0))),
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

    /// @notice Parses identity-bound artifacts in manifest market order, without deriving proofs or workflow IDs.
    function readOfficialArtifacts(DeployRealisticTestnetScript.Deployment memory deployed, string memory json)
        public
        view
        returns (WorkflowArtifact[] memory artifacts)
    {
        if (
            vm.parseJsonUint(json, ".chainId") != deployed.chainId
                || vm.parseJsonAddress(json, ".chainlinkRegistry") != deployed.chainlinkRegistry
                || vm.parseJsonAddress(json, ".owner") != deployed.owner || deployed.markets.length == 0
                || vm.keyExistsJson(json, string.concat(".entries[", deployed.markets.length.toString(), "]"))
        ) revert InvalidActivation();
        artifacts = new WorkflowArtifact[](deployed.markets.length);
        for (uint256 i; i < artifacts.length; ++i) {
            string memory key = string.concat(".entries[", i.toString(), "]");
            uint256 expiry = vm.parseJsonUint(json, string.concat(key, ".expiry"));
            if (expiry > type(uint48).max) revert InvalidActivation();
            artifacts[i] = WorkflowArtifact({
                oracle: vm.parseJsonAddress(json, string.concat(key, ".oracle")),
                wrapper: vm.parseJsonAddress(json, string.concat(key, ".wrapper")),
                expiry: uint48(expiry),
                proof: vm.parseJsonBytes32(json, string.concat(key, ".proof")),
                signature: vm.parseJsonBytes(json, string.concat(key, ".signature")),
                workflowId: vm.parseJsonBytes32(json, string.concat(key, ".workflowId")),
                params: ICREWorkflowRegistry.WorkflowParams({
                    tag: vm.keyExistsJson(json, string.concat(key, ".tag"))
                        ? vm.parseJsonString(json, string.concat(key, ".tag"))
                        : "default",
                    status: vm.keyExistsJson(json, string.concat(key, ".status"))
                        ? IChainlinkWorkflowRegistry.WorkflowStatus(
                            vm.parseJsonUint(json, string.concat(key, ".status"))
                        )
                        : IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE,
                    donFamily: vm.parseJsonString(json, string.concat(key, ".donFamily")),
                    binaryUrl: vm.parseJsonString(json, string.concat(key, ".binaryUrl")),
                    configUrl: vm.parseJsonString(json, string.concat(key, ".configUrl")),
                    attributes: vm.parseJsonBytes(json, string.concat(key, ".attributes"))
                })
            });
        }
    }

    /// @notice Validates every supplied official artifact before linking and accepting the exact workflows on Sepolia.
    function runOfficialBase(
        DeployRealisticTestnetScript.Deployment memory deployed,
        WorkflowArtifact[] memory artifacts
    ) public {
        if (
            block.chainid != 11_155_111 || deployed.chainId != block.chainid || deployed.owner == address(0)
                || deployed.forwarder != 0xF8344CFd5c43616a4366C34E3EEE75af79a74482
                || deployed.forwarder.code.length == 0 || deployed.chainlinkRegistry.code.length == 0
                || artifacts.length == 0 || artifacts.length != deployed.markets.length
                || keccak256(bytes(ITestnetCREActivationRegistry(deployed.chainlinkRegistry).typeAndVersion()))
                    != keccak256("WorkflowRegistry 2.0.0")
        ) revert InvalidActivation();
        bool[] memory linked = new bool[](artifacts.length);
        bool[] memory accepted = new bool[](artifacts.length);
        for (uint256 i; i < artifacts.length; ++i) {
            WorkflowArtifact memory artifact = artifacts[i];
            address adapter = deployed.markets[i].merkle.adapter;
            if (
                artifact.oracle != IMerkleAdapter(adapter).oracle()
                    || artifact.wrapper != deployed.markets[i].merkle.workflowRegistry || artifact.proof == bytes32(0)
                    || artifact.signature.length == 0 || artifact.workflowId == bytes32(0)
                    || bytes(artifact.params.tag).length == 0 || bytes(artifact.params.donFamily).length == 0
                    || bytes(artifact.params.binaryUrl).length == 0
                    || Ownable(artifact.wrapper).owner() != deployed.owner
                    || Ownable(artifact.oracle).owner() != deployed.owner
                    || ICREWorkflowRegistry(artifact.wrapper).CHAINLINK_WORKFLOW_REGISTRY()
                        != deployed.chainlinkRegistry
                    || ICREOracle(artifact.oracle).WORKFLOW_REGISTRY() != artifact.wrapper
                    || ICREOracle(artifact.oracle).FORWARDER() != deployed.forwarder
                    || ICREOracle(artifact.oracle).adapter() != adapter
            ) revert InvalidActivation();
            for (uint256 j; j < i; ++j) {
                if (
                    artifact.oracle == artifacts[j].oracle || artifact.wrapper == artifacts[j].wrapper
                        || artifact.proof == artifacts[j].proof || artifact.workflowId == artifacts[j].workflowId
                ) revert InvalidActivation();
            }
            linked[i] = ITestnetCREActivationRegistry(deployed.chainlinkRegistry).isOwnerLinked(artifact.wrapper);
            bytes32 currentId = ICREWorkflowRegistry(artifact.wrapper).workflowId(artifact.oracle);
            if (currentId != bytes32(0)) {
                IChainlinkWorkflowRegistry.WorkflowMetadataView memory registered = IChainlinkWorkflowRegistry(
                        deployed.chainlinkRegistry
                    )
                    .getWorkflow(artifact.wrapper, Strings.toHexString(artifact.oracle), artifact.params.tag);
                if (
                    currentId != artifact.workflowId || registered.workflowId != artifact.workflowId
                        || registered.owner != artifact.wrapper || registered.status != artifact.params.status
                        || keccak256(bytes(registered.workflowName))
                            != keccak256(bytes(Strings.toHexString(artifact.oracle)))
                        || keccak256(bytes(registered.tag)) != keccak256(bytes(artifact.params.tag))
                        || keccak256(bytes(registered.donFamily)) != keccak256(bytes(artifact.params.donFamily))
                        || keccak256(bytes(registered.binaryUrl)) != keccak256(bytes(artifact.params.binaryUrl))
                        || keccak256(bytes(registered.configUrl)) != keccak256(bytes(artifact.params.configUrl))
                        || keccak256(registered.attributes) != keccak256(artifact.params.attributes) || !linked[i]
                ) revert InvalidActivation();
                accepted[i] = true;
            }
            if (!linked[i]) {
                if (artifact.expiry <= block.timestamp) revert InvalidActivation();
                ITestnetCREActivationRegistry(deployed.chainlinkRegistry)
                    .canLinkOwner(artifact.wrapper, artifact.expiry, artifact.proof, artifact.signature);
            }
        }
        _start(deployed.owner);
        for (uint256 i; i < artifacts.length; ++i) {
            if (accepted[i]) continue;
            if (!linked[i]) {
                ICREWorkflowRegistry(artifacts[i].wrapper)
                    .linkOwner(artifacts[i].expiry, artifacts[i].proof, artifacts[i].signature);
            }
            ICREWorkflowRegistry(artifacts[i].wrapper)
                .proposeWorkflow(artifacts[i].oracle, artifacts[i].workflowId, artifacts[i].params);
            ICREWorkflowRegistry(artifacts[i].wrapper)
                .acceptWorkflow(artifacts[i].oracle, artifacts[i].workflowId, artifacts[i].params);
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
