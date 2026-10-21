// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";

import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IChainlinkWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/IChainlinkWorkflowRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Test} from "forge-std/Test.sol";

import {ActivateMerkleTestnetScript} from "script/deploy/testnet/ActivateMerkleTestnet.s.sol";
import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {ReportMerkleTestnetScript} from "script/deploy/testnet/ReportMerkleTestnet.s.sol";
import {SyncMerkleTestnetScript} from "script/deploy/testnet/SyncMerkleTestnet.s.sol";
import {TestnetPhaseScript} from "script/deploy/testnet/base/TestnetPhase.s.sol";

import {IWorkflowRegistry} from "test/mocks/chainlink-cre/interfaces/IWorkflowRegistry.sol";

contract OfficialActivationHarness is ActivateMerkleTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract OfficialSyncHarness is SyncMerkleTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract OfficialPhaseAdapter {
    address public oracle;
    uint256 public syncCount;

    function setOracle(address newOracle) public {
        oracle = newOracle;
    }

    function vault() public view returns (address) {
        return address(this);
    }

    function delegator() public view returns (address) {
        return address(this);
    }

    function sweepPending() public returns (uint256) {
        ++syncCount;
        return 0;
    }
}

contract OfficialPhaseOracle is Ownable {
    address public immutable adapter;
    address public immutable WORKFLOW_REGISTRY;
    address public immutable FORWARDER;
    uint48 public snapshotBlock;

    constructor(address newOwner, address newAdapter, address newRegistry, address newForwarder) Ownable(newOwner) {
        adapter = newAdapter;
        WORKFLOW_REGISTRY = newRegistry;
        FORWARDER = newForwarder;
    }

    function setSnapshot(uint48 newBlock) public {
        snapshotBlock = newBlock;
    }

    function latestSnapshot() public view returns (uint48, uint256) {
        return (snapshotBlock, 0);
    }
}

contract OfficialCREPhasesTest is Test {
    uint256 internal constant _LINK_SIGNER_KEY = 0xC0DE;
    uint256 internal constant _OWNER_KEY = 0xB0B;
    address internal constant _FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    DeployRealisticTestnetScript.Deployment internal _deployed;
    address internal _activation;
    address internal _sync;
    address internal _report;

    function setUp() public {
        vm.chainId(11_155_111);
        vm.warp(1_800_000_000);
        vm.roll(100);
        vm.etch(_FORWARDER, hex"00");
        _deployed.chainId = block.chainid;
        _deployed.owner = vm.addr(_OWNER_KEY);
        _deployed.forwarder = _FORWARDER;
        _deployed.chainlinkRegistry = deployCode("WorkflowRegistry.sol:WorkflowRegistry");
        _deployed.vaultFactory = _deployed.chainlinkRegistry;
        address[] memory signers = new address[](1);
        signers[0] = vm.addr(_LINK_SIGNER_KEY);
        IWorkflowRegistry(_deployed.chainlinkRegistry).updateAllowedSigners(signers, true);
        IWorkflowRegistry(_deployed.chainlinkRegistry).setDONLimit("sepolia-don", 100, 100);
        for (uint256 i; i < 2; ++i) {
            _deployed.markets.push();
            address wrapper = address(new CREWorkflowRegistry(_deployed.owner, _deployed.chainlinkRegistry));
            address adapter = address(new OfficialPhaseAdapter());
            address oracle = address(new OfficialPhaseOracle(_deployed.owner, adapter, wrapper, _FORWARDER));
            OfficialPhaseAdapter(adapter).setOracle(oracle);
            _deployed.markets[i].merkle.adapter = adapter;
            _deployed.markets[i].merkle.workflowRegistry = wrapper;
        }
        _activation = address(new OfficialActivationHarness());
        _sync = address(new OfficialSyncHarness());
        _report = address(new ReportMerkleTestnetScript());
    }

    function test_OfficialArtifactsUseAuthorizedSignaturesAndExactWorkflowData() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        for (uint256 i; i < artifacts.length; ++i) {
            assertTrue(IWorkflowRegistry(_deployed.chainlinkRegistry).isOwnerLinked(artifacts[i].wrapper));
            assertEq(
                ICREWorkflowRegistry(artifacts[i].wrapper).workflowId(artifacts[i].oracle), artifacts[i].workflowId
            );
            IWorkflowRegistry.WorkflowMetadataView memory registered =
                IWorkflowRegistry(_deployed.chainlinkRegistry).getWorkflowById(artifacts[i].workflowId);
            assertEq(registered.owner, artifacts[i].wrapper);
            assertEq(registered.tag, artifacts[i].params.tag);
            assertEq(uint256(registered.status), uint256(artifacts[i].params.status));
            assertEq(registered.donFamily, artifacts[i].params.donFamily);
            assertEq(registered.binaryUrl, artifacts[i].params.binaryUrl);
            assertEq(registered.configUrl, artifacts[i].params.configUrl);
            assertEq(registered.attributes, artifacts[i].params.attributes);
        }
    }

    function test_PausedArtifactStatusIsParsedRegisteredAndResumed() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        artifacts[0].params.status = IChainlinkWorkflowRegistry.WorkflowStatus.PAUSED;
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory parsed =
            OfficialActivationHarness(_activation).readOfficialArtifacts(_deployed, _json(artifacts, true));
        assertEq(abi.encode(parsed), abi.encode(artifacts));
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, parsed);
        assertEq(
            uint256(IWorkflowRegistry(_deployed.chainlinkRegistry).getWorkflowById(parsed[0].workflowId).status),
            uint256(IWorkflowRegistry.WorkflowStatus.PAUSED)
        );
        vm.warp(block.timestamp + 2 days);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, parsed);
        assertEq(IWorkflowRegistry(_deployed.chainlinkRegistry).totalActiveWorkflowsOnDON("sepolia-don"), 1);
    }

    function test_OwnerSignedProofsCannotActivateOfficialPhase() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_OWNER_KEY);
        vm.expectRevert();
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        assertFalse(
            IWorkflowRegistry(_deployed.chainlinkRegistry).isOwnerLinked(_deployed.markets[0].merkle.workflowRegistry)
        );
    }

    function test_CompletedActivationCanResumeAfterProofExpiryWithoutReplacingWorkflows() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        uint64 createdAt =
            IWorkflowRegistry(_deployed.chainlinkRegistry).getWorkflowById(artifacts[0].workflowId).createdAt;
        vm.warp(block.timestamp + 2 days);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        assertEq(
            IWorkflowRegistry(_deployed.chainlinkRegistry).getWorkflowById(artifacts[0].workflowId).createdAt, createdAt
        );
        assertEq(IWorkflowRegistry(_deployed.chainlinkRegistry).totalActiveWorkflowsOnDON("sepolia-don"), 2);
    }

    function test_LinkedOnlyPartialActivationCanResumeWithItsConsumedExpiredProof() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory original = _artifacts(_LINK_SIGNER_KEY);
        vm.prank(_deployed.owner);
        ICREWorkflowRegistry(original[0].wrapper)
            .linkOwner(original[0].expiry, original[0].proof, original[0].signature);
        vm.warp(block.timestamp + 2 days);
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        artifacts[0] = original[0];
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        for (uint256 i; i < artifacts.length; ++i) {
            assertEq(
                ICREWorkflowRegistry(artifacts[i].wrapper).workflowId(artifacts[i].oracle), artifacts[i].workflowId
            );
        }
    }

    function test_ResumeRejectsChangedWorkflowIdMetadataOrStatus() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        artifacts[1].params.tag = "different-tag";
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        artifacts = _artifacts(_LINK_SIGNER_KEY);
        artifacts[1].params.binaryUrl = "https://example.com/different.wasm.br";
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        artifacts = _artifacts(_LINK_SIGNER_KEY);
        artifacts[1].workflowId = keccak256("replacement is not a resume");
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        artifacts = _artifacts(_LINK_SIGNER_KEY);
        IWorkflowRegistry(_deployed.chainlinkRegistry).adminPauseWorkflow(artifacts[1].workflowId);
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
    }

    function test_AllArtifactIdentitiesAndUniquenessAreValidated() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        artifacts[1].oracle = artifacts[0].oracle;
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        artifacts = _artifacts(_LINK_SIGNER_KEY);
        artifacts[1].proof = artifacts[0].proof;
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        artifacts = _artifacts(_LINK_SIGNER_KEY);
        artifacts[1].workflowId = artifacts[0].workflowId;
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        assertFalse(
            IWorkflowRegistry(_deployed.chainlinkRegistry).isOwnerLinked(_deployed.markets[0].merkle.workflowRegistry)
        );
    }

    function test_ArtifactJsonPreservesSuppliedValuesAndRejectsExtraOrWrongChainEntries() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        string memory json = _json(artifacts, true);
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory parsed =
            OfficialActivationHarness(_activation).readOfficialArtifacts(_deployed, json);
        assertEq(abi.encode(parsed), abi.encode(artifacts));
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, parsed);

        _deployed.chainId = 1;
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).readOfficialArtifacts(_deployed, json);
        _deployed.chainId = block.chainid;
        artifacts = new ActivateMerkleTestnetScript.WorkflowArtifact[](3);
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).readOfficialArtifacts(_deployed, _json(artifacts, true));
    }

    function test_ArtifactJsonWithoutTagOrStatusDefaultsToLegacyRegistration() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory parsed =
            OfficialActivationHarness(_activation).readOfficialArtifacts(_deployed, _json(artifacts, false));
        for (uint256 i; i < artifacts.length; ++i) {
            artifacts[i].params.tag = "default";
        }
        assertEq(abi.encode(parsed), abi.encode(artifacts));
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, parsed);
    }

    function test_LocalActivationAndReportRoutingAreBlockedOnSepolia() public {
        vm.expectRevert(ActivateMerkleTestnetScript.LocalActivationUnavailable.selector);
        OfficialActivationHarness(_activation).runBase(_deployed, 0, bytes32(0), new bytes[](0));
        vm.expectRevert(ReportMerkleTestnetScript.LocalReportingUnavailable.selector);
        ReportMerkleTestnetScript(_report).runBase(_deployed, 99, new uint256[](2));
        vm.expectRevert(ReportMerkleTestnetScript.LocalReportingUnavailable.selector);
        ReportMerkleTestnetScript(_report).run();
    }

    function test_SyncRequiresAllReportsAndUsesOnlyExistingSnapshots() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        OfficialPhaseOracle(artifacts[0].oracle).setSnapshot(99);
        vm.expectRevert(SyncMerkleTestnetScript.ReportUnavailable.selector);
        OfficialSyncHarness(_sync).runBase(_deployed);
        assertEq(OfficialPhaseAdapter(_deployed.markets[0].merkle.adapter).syncCount(), 0);
        OfficialPhaseOracle(artifacts[1].oracle).setSnapshot(99);
        OfficialSyncHarness(_sync).runBase(_deployed);
        for (uint256 i; i < artifacts.length; ++i) {
            assertEq(OfficialPhaseAdapter(_deployed.markets[i].merkle.adapter).syncCount(), 1);
            assertEq(OfficialPhaseOracle(artifacts[i].oracle).snapshotBlock(), 99);
        }
    }

    function test_SyncRejectsMissingWorkflowAndUncompletedSnapshotsButAllowsDelay() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        for (uint256 i; i < artifacts.length; ++i) {
            OfficialPhaseOracle(artifacts[i].oracle).setSnapshot(99);
        }
        vm.expectRevert(SyncMerkleTestnetScript.ReportUnavailable.selector);
        OfficialSyncHarness(_sync).runBase(_deployed);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        OfficialPhaseOracle(artifacts[1].oracle).setSnapshot(100);
        vm.expectRevert(SyncMerkleTestnetScript.ReportUnavailable.selector);
        OfficialSyncHarness(_sync).runBase(_deployed);
        OfficialPhaseOracle(artifacts[1].oracle).setSnapshot(99);
        vm.warp(block.timestamp + 365 days);
        OfficialSyncHarness(_sync).runBase(_deployed);
    }

    function test_SyncLoadsHumanReadableManifestAndSynchronizesAllMarkets() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        address[] memory adapters = new address[](artifacts.length);
        address[] memory registries = new address[](artifacts.length);
        for (uint256 i; i < artifacts.length; ++i) {
            adapters[i] = _deployed.markets[i].merkle.adapter;
            registries[i] = artifacts[i].wrapper;
            OfficialPhaseOracle(artifacts[i].oracle).setSnapshot(99);
        }
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        vm.setEnv("TESTNET_MANIFEST", _syncManifest(2, adapters, registries));
        DeployRealisticTestnetScript.Deployment memory loaded = OfficialSyncHarness(_sync).load();
        assertEq(loaded.chainId, _deployed.chainId);
        assertEq(loaded.owner, _deployed.owner);
        assertEq(loaded.chainlinkRegistry, _deployed.chainlinkRegistry);
        assertEq(loaded.forwarder, _deployed.forwarder);
        assertEq(loaded.markets.length, artifacts.length);
        OfficialSyncHarness(_sync).run();
        for (uint256 i; i < artifacts.length; ++i) {
            assertEq(loaded.markets[i].merkle.adapter, adapters[i]);
            assertEq(loaded.markets[i].merkle.workflowRegistry, registries[i]);
            assertEq(OfficialPhaseAdapter(adapters[i]).syncCount(), 1);
        }
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
    }

    function test_SyncManifestRejectsWrongSchemaChainAndMarketCardinality() public {
        address[] memory adapters = new address[](1);
        address[] memory registries = new address[](1);
        adapters[0] = _deployed.markets[0].merkle.adapter;
        registries[0] = _deployed.markets[0].merkle.workflowRegistry;
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        vm.setEnv("TESTNET_MANIFEST", _syncManifest(1, adapters, registries));
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        OfficialSyncHarness(_sync).load();
        _deployed.chainId = 1;
        vm.setEnv("TESTNET_MANIFEST", _syncManifest(2, adapters, registries));
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        OfficialSyncHarness(_sync).load();
        _deployed.chainId = block.chainid;
        vm.setEnv("TESTNET_MANIFEST", _syncManifest(2, adapters, new address[](0)));
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        OfficialSyncHarness(_sync).load();
        vm.setEnv("TESTNET_MANIFEST", _syncManifest(2, new address[](0), new address[](0)));
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        OfficialSyncHarness(_sync).load();
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
    }

    function test_OfficialActivationRejectsWrongForwarderAndExpiredArtifacts() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts(_LINK_SIGNER_KEY);
        _deployed.forwarder = address(this);
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
        _deployed.forwarder = _FORWARDER;
        artifacts[1].expiry = uint48(block.timestamp);
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runOfficialBase(_deployed, artifacts);
    }

    function _syncManifest(uint256 schemaVersion, address[] memory adapters, address[] memory registries)
        internal
        returns (string memory path)
    {
        vm.serializeJson("sync-manifest-test", "{}");
        vm.serializeUint("sync-manifest-test", "schemaVersion", schemaVersion);
        vm.serializeUint("sync-manifest-test", "chainId", _deployed.chainId);
        vm.serializeUint("sync-manifest-test", "startBlock", 98);
        vm.serializeAddress("sync-manifest-test", "owner", _deployed.owner);
        vm.serializeAddress("sync-manifest-test", "vaultFactory", _deployed.vaultFactory);
        vm.serializeAddress("sync-manifest-test", "chainlinkRegistry", _deployed.chainlinkRegistry);
        vm.serializeAddress("sync-manifest-test", "forwarder", _deployed.forwarder);
        vm.serializeAddress("sync-manifest-test", "merkleAdapters", adapters);
        string memory json = vm.serializeAddress("sync-manifest-test", "workflowRegistries", registries);
        path = "script/deploy/testnet/manifests/sync-loader-test.json";
        vm.createDir("script/deploy/testnet/manifests", true);
        vm.writeFile(path, json);
    }

    function _artifacts(uint256 signerKey)
        internal
        view
        returns (ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts)
    {
        artifacts = new ActivateMerkleTestnetScript.WorkflowArtifact[](_deployed.markets.length);
        for (uint256 i; i < artifacts.length; ++i) {
            address wrapper = _deployed.markets[i].merkle.workflowRegistry;
            uint48 expiry = uint48(block.timestamp + 1 days);
            bytes32 proof = keccak256(abi.encode("externally supplied proof", i));
            bytes32 digest = keccak256(
                abi.encode(
                    uint8(0),
                    wrapper,
                    block.chainid,
                    _deployed.chainlinkRegistry,
                    "WorkflowRegistry 2.0.0",
                    uint256(expiry),
                    proof
                )
            );
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(signerKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)));
            artifacts[i] = ActivateMerkleTestnetScript.WorkflowArtifact({
                oracle: IMerkleAdapter(_deployed.markets[i].merkle.adapter).oracle(),
                wrapper: wrapper,
                expiry: expiry,
                proof: proof,
                signature: abi.encodePacked(r, s, v),
                workflowId: keccak256(abi.encode("externally compiled workflow", i)),
                params: ICREWorkflowRegistry.WorkflowParams({
                    tag: "deployment-v1",
                    status: IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE,
                    donFamily: "sepolia-don",
                    binaryUrl: "https://example.com/compiled.wasm.br",
                    configUrl: "https://example.com/real-config.json",
                    attributes: hex"0102"
                })
            });
        }
    }

    function _json(ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts, bool includeTag)
        internal
        returns (string memory json)
    {
        vm.serializeJson("activation-test", "{}");
        vm.serializeUint("activation-test", "chainId", _deployed.chainId);
        vm.serializeAddress("activation-test", "owner", _deployed.owner);
        json = vm.serializeAddress("activation-test", "chainlinkRegistry", _deployed.chainlinkRegistry);
        string memory entries = "[";
        for (uint256 i; i < artifacts.length; ++i) {
            string memory key = string.concat("activation-entry-", vm.toString(i));
            vm.serializeJson(key, "{}");
            vm.serializeAddress(key, "oracle", artifacts[i].oracle);
            vm.serializeAddress(key, "wrapper", artifacts[i].wrapper);
            vm.serializeUint(key, "expiry", artifacts[i].expiry);
            vm.serializeBytes32(key, "proof", artifacts[i].proof);
            vm.serializeBytes(key, "signature", artifacts[i].signature);
            vm.serializeBytes32(key, "workflowId", artifacts[i].workflowId);
            if (includeTag) {
                vm.serializeString(key, "tag", artifacts[i].params.tag);
                vm.serializeUint(key, "status", uint256(artifacts[i].params.status));
            }
            vm.serializeString(key, "donFamily", artifacts[i].params.donFamily);
            vm.serializeString(key, "binaryUrl", artifacts[i].params.binaryUrl);
            vm.serializeString(key, "configUrl", artifacts[i].params.configUrl);
            string memory row = vm.serializeBytes(key, "attributes", artifacts[i].params.attributes);
            entries = string.concat(entries, i == 0 ? "" : ",", row);
        }
        entries = string.concat(entries, "]");
        return vm.serializeJson(
            "activation-test",
            string.concat(string(Bytes.slice(bytes(json), 0, bytes(json).length - 1)), ",\"entries\":", entries, "}")
        );
    }
}
