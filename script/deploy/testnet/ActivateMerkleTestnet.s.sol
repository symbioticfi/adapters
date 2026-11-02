// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployRealisticTestnetScript} from "./DeployRealisticTestnet.s.sol";
import {SepoliaInfrastructure} from "./SepoliaInfrastructure.sol";
import {TestnetPhaseScript} from "./base/TestnetPhase.s.sol";
import {OfficialCRE} from "../merkle/OfficialCRE.sol";
import {WorkflowRegistry} from "test/mocks/chainlink-cre/WorkflowRegistry.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IChainlinkWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/IChainlinkWorkflowRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title ITestnetCREActivationRegistry
 * @notice Interface for inspecting upstream registry ownership without submitting transactions.
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
/// @notice Mirrors verified mainnet registrations into the Sepolia replica and accepts each oracle's workflow.
contract ActivateMerkleTestnetScript is TestnetPhaseScript {
    using Strings for uint256;

    error InvalidActivation();
    error LocalActivationUnavailable();

    struct OwnerLink {
        uint48 expiry;
        bytes32 proof;
        bytes signature;
    }

    struct WorkflowArtifact {
        address oracle;
        bytes32 workflowId;
        ICREWorkflowRegistry.WorkflowParams params;
    }

    function run() public {
        DeployRealisticTestnetScript.Deployment memory deployed = load();
        if (block.chainid == SepoliaInfrastructure.CHAIN_ID) {
            WorkflowArtifact[] memory artifacts =
                readArtifacts(deployed, vm.readFile(vm.envString("TESTNET_CRE_ACTIVATION")));
            uint256 destinationFork = vm.activeFork();
            vm.createSelectFork(vm.envString("CRE_MAINNET_RPC_URL"));
            verifyRegistration(deployed.markets[0].merkle.workflowRegistry, artifacts);
            vm.selectFork(destinationFork);
            uint48 expiry = uint48(block.timestamp + 1 days);
            bytes32 proof = keccak256(abi.encode(deployed.chainlinkRegistry, deployed.owner, block.number));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(
                deployed.owner,
                keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", linkHash(deployed, expiry, proof)))
            );
            runSepoliaBase(
                deployed, OwnerLink({expiry: expiry, proof: proof, signature: abi.encodePacked(r, s, v)}), artifacts
            );
            return;
        }
        uint48 expiry = uint48(block.timestamp + 1 days);
        bytes32 proof = keccak256(abi.encode(deployed.chainlinkRegistry, deployed.owner, block.number, block.timestamp));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", linkHash(deployed, expiry, proof)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployed.owner, digest);
        runBase(deployed, expiry, proof, abi.encodePacked(r, s, v));
    }

    function runBase(
        DeployRealisticTestnetScript.Deployment memory deployed,
        uint48 expiry,
        bytes32 proof,
        bytes memory signature
    ) public {
        if (block.chainid != 31_337) revert LocalActivationUnavailable();
        ICREWorkflowRegistry.WorkflowParams memory params = ICREWorkflowRegistry.WorkflowParams({
            tag: vm.envOr("TESTNET_WORKFLOW_TAG", string("default")),
            status: IChainlinkWorkflowRegistry.WorkflowStatus(vm.envOr("TESTNET_WORKFLOW_STATUS", uint256(0))),
            donFamily: "testnet",
            binaryUrl: vm.envOr("TESTNET_WORKFLOW_BINARY_URL", string("https://localhost/testnet-nav.wasm.br")),
            configUrl: vm.envOr("TESTNET_WORKFLOW_CONFIG_URL", string("https://localhost/testnet-nav.json")),
            attributes: ""
        });
        WorkflowArtifact[] memory artifacts = new WorkflowArtifact[](deployed.markets.length);
        for (uint256 i; i < deployed.markets.length; ++i) {
            address oracle = IMerkleAdapter(deployed.markets[i].merkle.adapter).oracle();
            artifacts[i] = WorkflowArtifact({
                oracle: oracle,
                workflowId: keccak256(abi.encode(block.chainid, oracle, deployed.startBlock)),
                params: params
            });
        }
        _activateBase(deployed, OwnerLink({expiry: expiry, proof: proof, signature: signature}), artifacts);
    }

    /// @notice Parses identity-bound artifacts in manifest market order, without deriving proofs or workflow IDs.
    function readArtifacts(DeployRealisticTestnetScript.Deployment memory deployed, string memory json)
        public
        view
        returns (WorkflowArtifact[] memory artifacts)
    {
        if (
            vm.parseJsonUint(json, ".chainId") != deployed.chainId
                || vm.parseJsonAddress(json, ".chainlinkRegistry") != deployed.chainlinkRegistry
                || vm.parseJsonAddress(json, ".owner") != deployed.owner || deployed.markets.length == 0
                || vm.parseJsonAddress(json, ".workflowRegistry") != deployed.markets[0].merkle.workflowRegistry
                || vm.keyExistsJson(json, string.concat(".entries[", deployed.markets.length.toString(), "]"))
        ) revert InvalidActivation();
        artifacts = new WorkflowArtifact[](deployed.markets.length);
        for (uint256 i; i < artifacts.length; ++i) {
            string memory key = string.concat(".entries[", i.toString(), "]");
            artifacts[i] = WorkflowArtifact({
                oracle: vm.parseJsonAddress(json, string.concat(key, ".oracle")),
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

    /// @notice Checks actual mainnet registration records before any Sepolia transaction is prepared.
    function verifyRegistration(address workflowOwner, WorkflowArtifact[] memory artifacts) public view {
        if (
            block.chainid != 1 || artifacts.length == 0
                || !ITestnetCREActivationRegistry(OfficialCRE.MAINNET_REGISTRY).isOwnerLinked(workflowOwner)
        ) revert InvalidActivation();
        for (uint256 i; i < artifacts.length; ++i) {
            WorkflowArtifact memory artifact = artifacts[i];
            IChainlinkWorkflowRegistry.WorkflowMetadataView memory registered = IChainlinkWorkflowRegistry(
                    OfficialCRE.MAINNET_REGISTRY
                )
                .getWorkflow(workflowOwner, Strings.toHexString(artifact.oracle), artifact.params.tag);
            if (
                registered.owner != workflowOwner || registered.workflowId != artifact.workflowId
                    || keccak256(bytes(registered.workflowName))
                        != keccak256(bytes(Strings.toHexString(artifact.oracle)))
                    || keccak256(abi.encode(artifact.params))
                        != keccak256(
                            abi.encode(
                                ICREWorkflowRegistry.WorkflowParams({
                                    tag: registered.tag,
                                    status: registered.status,
                                    donFamily: registered.donFamily,
                                    binaryUrl: registered.binaryUrl,
                                    configUrl: registered.configUrl,
                                    attributes: registered.attributes
                                })
                            )
                        )
            ) revert InvalidActivation();
        }
    }

    /// @notice Validates the Sepolia replica before proposal/acceptance with the operator's local link proof.
    function runSepoliaBase(
        DeployRealisticTestnetScript.Deployment memory deployed,
        OwnerLink memory link,
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
        SepoliaInfrastructure.validateCRE(deployed.chainlinkRegistry);
        _activateBase(deployed, link, artifacts);
    }

    function _activateBase(
        DeployRealisticTestnetScript.Deployment memory deployed,
        OwnerLink memory link,
        WorkflowArtifact[] memory artifacts
    ) internal {
        if (
            deployed.chainId != block.chainid || deployed.owner == address(0) || artifacts.length == 0
                || artifacts.length != deployed.markets.length || link.proof == bytes32(0) || link.signature.length == 0
        ) {
            revert InvalidActivation();
        }
        address registry = deployed.markets[0].merkle.workflowRegistry;
        if (
            Ownable(registry).owner() != deployed.owner
                || ICREWorkflowRegistry(registry).CHAINLINK_WORKFLOW_REGISTRY() != deployed.chainlinkRegistry
        ) revert InvalidActivation();
        bool linked = ITestnetCREActivationRegistry(deployed.chainlinkRegistry).isOwnerLinked(registry);
        bool[] memory accepted = new bool[](artifacts.length);
        for (uint256 i; i < artifacts.length; ++i) {
            WorkflowArtifact memory artifact = artifacts[i];
            address adapter = deployed.markets[i].merkle.adapter;
            if (
                artifact.oracle != IMerkleAdapter(adapter).oracle()
                    || registry != deployed.markets[i].merkle.workflowRegistry || artifact.workflowId == bytes32(0)
                    || bytes(artifact.params.tag).length == 0 || bytes(artifact.params.donFamily).length == 0
                    || bytes(artifact.params.binaryUrl).length == 0
                    || Ownable(artifact.oracle).owner() != deployed.owner
                    || ICREOracle(artifact.oracle).WORKFLOW_REGISTRY() != registry
                    || ICREOracle(artifact.oracle).FORWARDER() != deployed.forwarder
                    || ICREOracle(artifact.oracle).adapter() != adapter
            ) revert InvalidActivation();
            for (uint256 j; j < i; ++j) {
                if (artifact.oracle == artifacts[j].oracle || artifact.workflowId == artifacts[j].workflowId) {
                    revert InvalidActivation();
                }
            }
            bytes32 currentId = ICREWorkflowRegistry(registry).workflowId(artifact.oracle);
            if (currentId != bytes32(0)) {
                IChainlinkWorkflowRegistry.WorkflowMetadataView memory registered = IChainlinkWorkflowRegistry(
                        deployed.chainlinkRegistry
                    )
                    .getWorkflow(registry, Strings.toHexString(artifact.oracle), artifact.params.tag);
                if (
                    currentId != artifact.workflowId || registered.workflowId != artifact.workflowId
                        || registered.owner != registry || registered.status != artifact.params.status
                        || keccak256(bytes(registered.workflowName))
                            != keccak256(bytes(Strings.toHexString(artifact.oracle)))
                        || keccak256(bytes(registered.tag)) != keccak256(bytes(artifact.params.tag))
                        || keccak256(bytes(registered.donFamily)) != keccak256(bytes(artifact.params.donFamily))
                        || keccak256(bytes(registered.binaryUrl)) != keccak256(bytes(artifact.params.binaryUrl))
                        || keccak256(bytes(registered.configUrl)) != keccak256(bytes(artifact.params.configUrl))
                        || keccak256(registered.attributes) != keccak256(artifact.params.attributes) || !linked
                ) revert InvalidActivation();
                accepted[i] = true;
            }
        }
        if (!linked) {
            if (link.expiry <= block.timestamp) revert InvalidActivation();
            ITestnetCREActivationRegistry(deployed.chainlinkRegistry)
                .canLinkOwner(registry, link.expiry, link.proof, link.signature);
        }
        _start(deployed.owner);
        if (block.chainid == SepoliaInfrastructure.CHAIN_ID) {
            for (uint256 i; i < artifacts.length; ++i) {
                if (
                    WorkflowRegistry(deployed.chainlinkRegistry)
                            .getMaxWorkflowsPerUserDON(registry, artifacts[i].params.donFamily) == 0
                ) {
                    WorkflowRegistry(deployed.chainlinkRegistry).setDONLimit(artifacts[i].params.donFamily, 100, 100);
                }
            }
        }
        if (!linked) ICREWorkflowRegistry(registry).linkOwner(link.expiry, link.proof, link.signature);
        for (uint256 i; i < artifacts.length; ++i) {
            if (accepted[i]) continue;
            ICREWorkflowRegistry(registry)
                .proposeWorkflow(artifacts[i].oracle, artifacts[i].workflowId, artifacts[i].params);
            ICREWorkflowRegistry(registry)
                .acceptWorkflow(artifacts[i].oracle, artifacts[i].workflowId, artifacts[i].params);
        }
        _stop();
    }

    function linkHash(DeployRealisticTestnetScript.Deployment memory deployed, uint48 expiry, bytes32 proof)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                uint8(0),
                deployed.markets[0].merkle.workflowRegistry,
                block.chainid,
                deployed.chainlinkRegistry,
                "WorkflowRegistry 2.0.0",
                uint256(expiry),
                proof
            )
        );
    }
}
