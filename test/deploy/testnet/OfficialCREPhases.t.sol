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
import {SepoliaInfrastructure} from "script/deploy/testnet/SepoliaInfrastructure.sol";
import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {SeedRealisticTestnetScript} from "script/deploy/testnet/SeedRealisticTestnet.s.sol";
import {SyncMerkleTestnetScript} from "script/deploy/testnet/SyncMerkleTestnet.s.sol";
import {TestnetPhaseScript} from "script/deploy/testnet/base/TestnetPhase.s.sol";

import {IWorkflowRegistry} from "test/mocks/chainlink-cre/interfaces/IWorkflowRegistry.sol";

contract OfficialActivationHarness is ActivateMerkleTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract PhaseFixture {
    struct Market {
        address adapter;
        address workflowRegistry;
    }

    struct Config {
        uint256 chainId;
        address owner;
        address chainlinkRegistry;
        address forwarder;
        address vaultFactory;
        Market[] markets;
    }

    Config internal _deployed;

    function _deployment() internal view returns (DeployRealisticTestnetScript.Deployment memory deployed) {
        deployed.chainId = _deployed.chainId;
        deployed.owner = _deployed.owner;
        deployed.chainlinkRegistry = _deployed.chainlinkRegistry;
        deployed.forwarder = _deployed.forwarder;
        deployed.vaultFactory = _deployed.vaultFactory;
        deployed.markets = new DeployRealisticTestnetScript.Market[](_deployed.markets.length);
        for (uint256 i; i < deployed.markets.length; ++i) {
            deployed.markets[i].merkle.adapter = _deployed.markets[i].adapter;
            deployed.markets[i].merkle.workflowRegistry = _deployed.markets[i].workflowRegistry;
        }
    }
}

contract WalletActivationHarness is OfficialActivationHarness, PhaseFixture {
    constructor(Config memory config) {
        _deployed = config;
    }

    function load() public view override returns (DeployRealisticTestnetScript.Deployment memory) {
        return _deployment();
    }
}

contract OfficialSyncHarness is SyncMerkleTestnetScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract SeedEntryHarness is SeedRealisticTestnetScript, PhaseFixture {
    constructor(Config memory config) {
        _deployed = config;
    }

    function load() public view override returns (DeployRealisticTestnetScript.Deployment memory) {
        return _deployment();
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

contract OfficialCREPhasesTest is Test, PhaseFixture {
    uint256 internal constant _LINK_SIGNER_KEY = 0xC0DE;
    uint256 internal constant _OWNER_KEY = 0xB0B;
    address internal constant _FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    address internal _activation;
    address internal _sync;

    function setUp() public {
        vm.chainId(11_155_111);
        vm.warp(1_800_000_000);
        vm.roll(100);
        vm.etch(_FORWARDER, deployCode("KeystoneForwarder.sol:KeystoneForwarder").code);
        _deployed.chainId = block.chainid;
        _deployed.owner = vm.addr(_OWNER_KEY);
        _deployed.forwarder = _FORWARDER;
        _deployed.chainlinkRegistry = deployCode("WorkflowRegistry.sol:WorkflowRegistry");
        _deployed.vaultFactory = _deployed.chainlinkRegistry;
        address[] memory signers = new address[](1);
        signers[0] = vm.addr(_LINK_SIGNER_KEY);
        IWorkflowRegistry(_deployed.chainlinkRegistry).updateAllowedSigners(signers, true);
        IWorkflowRegistry(_deployed.chainlinkRegistry).setDONLimit("sepolia-don", 100, 100);
        address wrapper = address(new CREWorkflowRegistry(_deployed.owner, _deployed.chainlinkRegistry));
        for (uint256 i; i < 2; ++i) {
            _deployed.markets.push();
            address adapter = address(new OfficialPhaseAdapter());
            address oracle = address(new OfficialPhaseOracle(_deployed.owner, adapter, wrapper, _FORWARDER));
            OfficialPhaseAdapter(adapter).setOracle(oracle);
            _deployed.markets[i].adapter = adapter;
            _deployed.markets[i].workflowRegistry = wrapper;
        }
        _activation = address(new OfficialActivationHarness());
        _sync = address(new OfficialSyncHarness());
    }

    function test_OfficialArtifactsUseAuthorizedSignaturesAndExactWorkflowData() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        ActivateMerkleTestnetScript.OwnerLink memory link = _ownerLink(_LINK_SIGNER_KEY);
        vm.expectCall(
            _deployed.chainlinkRegistry,
            abi.encodeCall(IChainlinkWorkflowRegistry.linkOwner, (link.expiry, link.proof, link.signature)),
            uint64(1)
        );
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        for (uint256 i; i < artifacts.length; ++i) {
            assertTrue(
                IWorkflowRegistry(_deployed.chainlinkRegistry).isOwnerLinked(_deployed.markets[i].workflowRegistry)
            );
            assertEq(
                ICREWorkflowRegistry(_deployed.markets[i].workflowRegistry).workflowId(artifacts[i].oracle),
                artifacts[i].workflowId
            );
            IWorkflowRegistry.WorkflowMetadataView memory registered =
                IWorkflowRegistry(_deployed.chainlinkRegistry).getWorkflowById(artifacts[i].workflowId);
            assertEq(registered.owner, _deployed.markets[i].workflowRegistry);
            assertEq(registered.tag, artifacts[i].params.tag);
            assertEq(uint256(registered.status), uint256(artifacts[i].params.status));
            assertEq(registered.donFamily, artifacts[i].params.donFamily);
            assertEq(registered.binaryUrl, artifacts[i].params.binaryUrl);
            assertEq(registered.configUrl, artifacts[i].params.configUrl);
            assertEq(registered.attributes, artifacts[i].params.attributes);
        }
    }

    function test_PausedArtifactStatusIsParsedRegisteredAndResumed() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        artifacts[0].params.status = IChainlinkWorkflowRegistry.WorkflowStatus.PAUSED;
        ActivateMerkleTestnetScript.OwnerLink memory parsedLink = _ownerLink(_LINK_SIGNER_KEY);
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory parsed =
            OfficialActivationHarness(_activation).readArtifacts(_deployment(), _json(artifacts, true));
        assertEq(abi.encode(parsed), abi.encode(artifacts));
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), parsedLink, parsed);
        assertEq(
            uint256(IWorkflowRegistry(_deployed.chainlinkRegistry).getWorkflowById(parsed[0].workflowId).status),
            uint256(IWorkflowRegistry.WorkflowStatus.PAUSED)
        );
        vm.warp(block.timestamp + 2 days);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), parsedLink, parsed);
        assertEq(IWorkflowRegistry(_deployed.chainlinkRegistry).totalActiveWorkflowsOnDON("sepolia-don"), 1);
    }

    function test_UnauthorizedSignerCannotLinkReplica() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        vm.expectRevert();
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_OWNER_KEY), artifacts);
        assertFalse(IWorkflowRegistry(_deployed.chainlinkRegistry).isOwnerLinked(_deployed.markets[0].workflowRegistry));
    }

    function test_CompletedActivationCanResumeAfterProofExpiryWithoutReplacingWorkflows() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        ActivateMerkleTestnetScript.OwnerLink memory link = _ownerLink(_LINK_SIGNER_KEY);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), link, artifacts);
        uint64 createdAt =
            IWorkflowRegistry(_deployed.chainlinkRegistry).getWorkflowById(artifacts[0].workflowId).createdAt;
        vm.warp(block.timestamp + 2 days);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), link, artifacts);
        assertEq(
            IWorkflowRegistry(_deployed.chainlinkRegistry).getWorkflowById(artifacts[0].workflowId).createdAt, createdAt
        );
        assertEq(IWorkflowRegistry(_deployed.chainlinkRegistry).totalActiveWorkflowsOnDON("sepolia-don"), 2);
    }

    function test_LinkedOnlyPartialActivationCanResumeWithItsConsumedExpiredProof() public {
        ActivateMerkleTestnetScript.OwnerLink memory link = _ownerLink(_LINK_SIGNER_KEY);
        vm.prank(_deployed.owner);
        ICREWorkflowRegistry(_deployed.markets[0].workflowRegistry).linkOwner(link.expiry, link.proof, link.signature);
        vm.warp(block.timestamp + 2 days);
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), link, artifacts);
        for (uint256 i; i < artifacts.length; ++i) {
            assertEq(
                ICREWorkflowRegistry(_deployed.markets[i].workflowRegistry).workflowId(artifacts[i].oracle),
                artifacts[i].workflowId
            );
        }
    }

    function test_ResumeRejectsChangedWorkflowIdMetadataOrStatus() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        artifacts[1].params.tag = "different-tag";
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        artifacts = _artifacts();
        artifacts[1].params.binaryUrl = "https://example.com/different.wasm.br";
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        artifacts = _artifacts();
        artifacts[1].workflowId = keccak256("replacement is not a resume");
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        artifacts = _artifacts();
        IWorkflowRegistry(_deployed.chainlinkRegistry).adminPauseWorkflow(artifacts[1].workflowId);
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
    }

    function test_AllArtifactIdentitiesAndUniquenessAreValidated() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        artifacts[1].oracle = artifacts[0].oracle;
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        artifacts = _artifacts();
        address shared = _deployed.markets[1].workflowRegistry;
        _deployed.markets[1].workflowRegistry =
            address(new CREWorkflowRegistry(_deployed.owner, _deployed.chainlinkRegistry));
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        _deployed.markets[1].workflowRegistry = shared;
        artifacts = _artifacts();
        artifacts[1].workflowId = artifacts[0].workflowId;
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        assertFalse(IWorkflowRegistry(_deployed.chainlinkRegistry).isOwnerLinked(_deployed.markets[0].workflowRegistry));
    }

    function test_ArtifactJsonPreservesSuppliedValuesAndRejectsExtraOrWrongChainEntries() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        string memory json = _json(artifacts, true);
        ActivateMerkleTestnetScript.OwnerLink memory parsedLink = _ownerLink(_LINK_SIGNER_KEY);
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory parsed =
            OfficialActivationHarness(_activation).readArtifacts(_deployment(), json);
        assertEq(abi.encode(parsed), abi.encode(artifacts));
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), parsedLink, parsed);

        _deployed.chainId = 1;
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).readArtifacts(_deployment(), json);
        _deployed.chainId = block.chainid;
        artifacts = new ActivateMerkleTestnetScript.WorkflowArtifact[](3);
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).readArtifacts(_deployment(), _json(artifacts, true));
    }

    function test_ArtifactJsonWithoutTagOrStatusDefaultsToActiveRegistration() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        ActivateMerkleTestnetScript.OwnerLink memory parsedLink = _ownerLink(_LINK_SIGNER_KEY);
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory parsed =
            OfficialActivationHarness(_activation).readArtifacts(_deployment(), _json(artifacts, false));
        for (uint256 i; i < artifacts.length; ++i) {
            artifacts[i].params.tag = "default";
        }
        assertEq(abi.encode(parsed), abi.encode(artifacts));
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), parsedLink, parsed);
    }

    function test_LocalActivationAndReportRoutingAreBlockedOnSepolia() public {
        vm.expectRevert(ActivateMerkleTestnetScript.LocalActivationUnavailable.selector);
        OfficialActivationHarness(_activation).runBase(_deployment(), 0, bytes32(0), "");
    }

    function test_SyncRequiresAllReportsAndUsesOnlyExistingSnapshots() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        OfficialPhaseOracle(artifacts[0].oracle).setSnapshot(99);
        vm.expectRevert(SyncMerkleTestnetScript.ReportUnavailable.selector);
        OfficialSyncHarness(_sync).runBase(_deployment());
        assertEq(OfficialPhaseAdapter(_deployed.markets[0].adapter).syncCount(), 0);
        OfficialPhaseOracle(artifacts[1].oracle).setSnapshot(99);
        OfficialSyncHarness(_sync).runBase(_deployment());
        for (uint256 i; i < artifacts.length; ++i) {
            assertEq(OfficialPhaseAdapter(_deployed.markets[i].adapter).syncCount(), 1);
            assertEq(OfficialPhaseOracle(artifacts[i].oracle).snapshotBlock(), 99);
        }
    }

    function test_SyncRejectsMissingWorkflowAndUncompletedSnapshotsButAllowsDelay() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        for (uint256 i; i < artifacts.length; ++i) {
            OfficialPhaseOracle(artifacts[i].oracle).setSnapshot(99);
        }
        vm.expectRevert(SyncMerkleTestnetScript.ReportUnavailable.selector);
        OfficialSyncHarness(_sync).runBase(_deployment());
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        OfficialPhaseOracle(artifacts[1].oracle).setSnapshot(100);
        vm.expectRevert(SyncMerkleTestnetScript.ReportUnavailable.selector);
        OfficialSyncHarness(_sync).runBase(_deployment());
        OfficialPhaseOracle(artifacts[1].oracle).setSnapshot(99);
        vm.warp(block.timestamp + 365 days);
        OfficialSyncHarness(_sync).runBase(_deployment());
    }

    function test_SyncLoadsHumanReadableManifestAndSynchronizesAllMarkets() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        address[] memory adapters = new address[](artifacts.length);
        address[] memory registries = new address[](artifacts.length);
        for (uint256 i; i < artifacts.length; ++i) {
            adapters[i] = _deployed.markets[i].adapter;
            registries[i] = _deployed.markets[i].workflowRegistry;
            OfficialPhaseOracle(artifacts[i].oracle).setSnapshot(99);
        }
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        vm.setEnv("TESTNET_MANIFEST", _syncManifest(1, adapters, registries));
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
        adapters[0] = _deployed.markets[0].adapter;
        registries[0] = _deployed.markets[0].workflowRegistry;
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        vm.setEnv("TESTNET_MANIFEST", _syncManifest(2, adapters, registries));
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        OfficialSyncHarness(_sync).load();
        _deployed.chainId = 1;
        vm.setEnv("TESTNET_MANIFEST", _syncManifest(1, adapters, registries));
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        OfficialSyncHarness(_sync).load();
        _deployed.chainId = block.chainid;
        vm.setEnv("TESTNET_MANIFEST", _syncManifest(1, adapters, new address[](0)));
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        OfficialSyncHarness(_sync).load();
        vm.setEnv("TESTNET_MANIFEST", _syncManifest(1, new address[](0), new address[](0)));
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        OfficialSyncHarness(_sync).load();
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
    }

    function test_OfficialActivationRejectsWrongForwarderAndExpiredArtifacts() public {
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        _deployed.forwarder = address(this);
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        _deployed.forwarder = _FORWARDER;
        ActivateMerkleTestnetScript.OwnerLink memory link = _ownerLink(_LINK_SIGNER_KEY);
        link.expiry = uint48(block.timestamp);
        vm.expectRevert(ActivateMerkleTestnetScript.InvalidActivation.selector);
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), link, artifacts);
    }

    function test_LocalActivationSignsWithLoadedFoundryWallet() public {
        vm.chainId(31_337);
        _deployed.chainId = block.chainid;
        vm.rememberKey(_OWNER_KEY);
        address[] memory signers = new address[](1);
        signers[0] = _deployed.owner;
        IWorkflowRegistry(_deployed.chainlinkRegistry).updateAllowedSigners(signers, true);
        IWorkflowRegistry(_deployed.chainlinkRegistry).setDONLimit("testnet", 100, 100);
        new WalletActivationHarness(_deployed).run();
        for (uint256 i; i < _deployed.markets.length; ++i) {
            assertTrue(
                CREWorkflowRegistry(_deployed.markets[i].workflowRegistry)
                    .workflowId(IMerkleAdapter(_deployed.markets[i].adapter).oracle()) != bytes32(0)
            );
        }
    }

    function test_SyncRejectsChangedUpstreamPinsAndWrongConfiguredOwner() public {
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        string memory previousOwner = vm.envOr("TESTNET_OWNER", string(""));
        address[] memory adapters = new address[](1);
        address[] memory registries = new address[](1);
        adapters[0] = _deployed.markets[0].adapter;
        registries[0] = _deployed.markets[0].workflowRegistry;
        string memory path = _syncManifest(1, adapters, registries);
        vm.setEnv("TESTNET_MANIFEST", path);
        vm.writeJson(vm.toString(bytes32(uint256(1))), path, ".upstreamPins");
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        OfficialSyncHarness(_sync).load();
        _syncManifest(1, adapters, registries);
        vm.setEnv("TESTNET_OWNER", vm.toString(address(0xBAD)));
        vm.expectRevert(TestnetPhaseScript.InvalidManifest.selector);
        OfficialSyncHarness(_sync).load();
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
        vm.setEnv("TESTNET_OWNER", previousOwner);
    }

    function test_SeedChecksBackingBeforeCreatingTransactions() public {
        SeedRealisticTestnetScript seed =
            SeedRealisticTestnetScript(deployCode("SeedRealisticTestnet.s.sol:SeedRealisticTestnetScript"));
        DeployRealisticTestnetScript.Deployment memory empty;
        empty.owner = address(0xBEEF);
        empty.seedAssets = 100_000;
        vm.expectRevert(bytes4(keccak256("InsufficientBacking()")));
        seed.runBase(empty);
    }

    function test_SeedRequiresInitialWorkflowsAndCompletedReportsBeforeFunding() public {
        vm.deal(_deployed.owner, 1000 ether);
        SeedEntryHarness seed = new SeedEntryHarness(_deployed);
        vm.expectRevert(SyncMerkleTestnetScript.ReportUnavailable.selector);
        seed.run();
        for (uint256 i; i < _deployed.markets.length; ++i) {
            OfficialPhaseOracle(IMerkleAdapter(_deployed.markets[i].adapter).oracle()).setSnapshot(99);
        }
        vm.expectRevert(SyncMerkleTestnetScript.ReportUnavailable.selector);
        seed.run();
        ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts = _artifacts();
        OfficialActivationHarness(_activation).runSepoliaBase(_deployment(), _ownerLink(_LINK_SIGNER_KEY), artifacts);
        OfficialPhaseOracle(artifacts[1].oracle).setSnapshot(100);
        vm.expectRevert(SyncMerkleTestnetScript.ReportUnavailable.selector);
        seed.run();
    }

    function test_ResumePreflightBindsOriginalManifestAndValidatesPins() public {
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        string memory previousWitness = vm.envOr("TESTNET_MANIFEST_WITNESS", string(""));
        string memory path = "script/deploy/testnet/manifests/resume-preflight-test.json";
        string memory witness = string.concat(path, ".hash");
        string memory json = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"owner":"',
            vm.toString(_deployed.owner),
            '","upstreamPins":"',
            vm.toString(sha256(bytes(vm.readFile("script/deploy/testnet/upstream/pins.json")))),
            '","startBlock":1}'
        );
        vm.writeFile(path, json);
        vm.writeFile(witness, vm.toString(keccak256(bytes(json))));
        vm.setEnv("TESTNET_MANIFEST", path);
        vm.setEnv("TESTNET_MANIFEST_WITNESS", witness);
        (bool ok,) = _sync.staticcall(abi.encodeWithSignature("checkManifest()"));
        assertTrue(ok, "original manifest must pass the read-only resume preflight");
        vm.writeFile(path, string.concat(json, " "));
        (ok,) = _sync.staticcall(abi.encodeWithSignature("checkManifest()"));
        assertFalse(ok, "replaced manifest must block resume");
        vm.writeJson(vm.toString(bytes32(uint256(1))), path, ".upstreamPins");
        json = vm.readFile(path);
        vm.writeFile(witness, vm.toString(keccak256(bytes(json))));
        (ok,) = _sync.staticcall(abi.encodeWithSignature("checkManifest()"));
        assertFalse(ok, "changed pins must block resume even with a matching file digest");
        vm.removeFile(path);
        vm.removeFile(witness);
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
        vm.setEnv("TESTNET_MANIFEST_WITNESS", previousWitness);
    }

    function test_DeploymentCannotOverwriteExistingManifest() public {
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        string memory path = "script/deploy/testnet/manifests/overwrite-test.json";
        vm.writeFile(path, "existing deployment");
        vm.setEnv("TESTNET_MANIFEST", path);
        DeployRealisticTestnetScript script =
            DeployRealisticTestnetScript(deployCode("DeployRealisticTestnet.s.sol:DeployRealisticTestnetScript"));
        vm.expectRevert(bytes4(keccak256("ManifestAlreadyExists()")));
        script.run();
        assertEq(vm.readFile(path), "existing deployment");
        vm.removeFile(path);
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
    }

    function _syncManifest(uint256 schemaVersion, address[] memory adapters, address[] memory registries)
        internal
        returns (string memory path)
    {
        vm.serializeJson("sync-manifest-test", "{}");
        vm.serializeUint("sync-manifest-test", "schemaVersion", schemaVersion);
        vm.serializeBytes32(
            "sync-manifest-test", "upstreamPins", sha256(bytes(vm.readFile("script/deploy/testnet/upstream/pins.json")))
        );
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

    function _ownerLink(uint256 signerKey) internal view returns (ActivateMerkleTestnetScript.OwnerLink memory link) {
        link.expiry = uint48(block.timestamp + 1 days);
        link.proof = keccak256("externally supplied owner proof");
        bytes32 digest = keccak256(
            abi.encode(
                uint8(0),
                _deployed.markets[0].workflowRegistry,
                block.chainid,
                _deployed.chainlinkRegistry,
                "WorkflowRegistry 2.0.0",
                uint256(link.expiry),
                link.proof
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)));
        link.signature = abi.encodePacked(r, s, v);
    }

    function _artifacts() internal view returns (ActivateMerkleTestnetScript.WorkflowArtifact[] memory artifacts) {
        artifacts = new ActivateMerkleTestnetScript.WorkflowArtifact[](_deployed.markets.length);
        for (uint256 i; i < artifacts.length; ++i) {
            artifacts[i] = ActivateMerkleTestnetScript.WorkflowArtifact({
                oracle: IMerkleAdapter(_deployed.markets[i].adapter).oracle(),
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
        vm.serializeAddress("activation-test", "chainlinkRegistry", _deployed.chainlinkRegistry);
        json = vm.serializeAddress("activation-test", "workflowRegistry", _deployed.markets[0].workflowRegistry);
        string memory entries = "[";
        for (uint256 i; i < artifacts.length; ++i) {
            string memory key = string.concat("activation-entry-", vm.toString(i));
            vm.serializeJson(key, "{}");
            vm.serializeAddress(key, "oracle", artifacts[i].oracle);
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
