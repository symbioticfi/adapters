// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployMerkleMainnetScript} from "script/deploy/merkle/DeployMerkleMainnet.s.sol";
import {OfficialCRE} from "script/deploy/merkle/OfficialCRE.sol";
import {IDeployMerkleAdapter} from "script/deploy/adapters/interfaces/IDeployMerkleAdapter.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {LiquidLaneConnector} from "src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {TestnetToken} from "script/deploy/testnet/protocols/TestnetAssets.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

contract OfficialVersion {
    bool private immutable _registry;

    constructor(bool registry_) {
        _registry = registry_;
    }

    function typeAndVersion() public view returns (string memory) {
        return _registry ? "WorkflowRegistry 2.0.0" : "KeystoneForwarder 1.0.0";
    }
}

contract DeployMerkleMainnetHarness is DeployMerkleMainnetScript {
    function _startBroadcast() internal override {}
    function _stopBroadcast() internal override {}

    function _scriptOwner() internal view override returns (address) {
        return address(this);
    }
}

contract DeployOfficialMerkleTest is Test {
    string private constant MANIFEST = "cache/mainnet-deployment-test.json";
    address private _script;
    address private _llFactory;
    address private _provider;
    address private _rootRegistryOwner;
    address private _workflowRegistryOwner;
    address private _oracleRegistryOwner;
    address private _capabilitiesRegistryOwner;

    function setUp() public {
        vm.chainId(1);
        vm.roll(1000);
        _script = address(new DeployMerkleMainnetHarness());
        _provider = makeAddr("provider");
        _rootRegistryOwner = makeAddr("root registry owner");
        _workflowRegistryOwner = makeAddr("workflow registry owner");
        _oracleRegistryOwner = makeAddr("oracle registry owner");
        _capabilitiesRegistryOwner = makeAddr("capabilities registry owner");
        _llFactory = address(new MigratablesFactory(address(this)));
        address registry = OfficialCRE.MAINNET_REGISTRY;
        address forwarder = OfficialCRE.MAINNET_FORWARDER;
        vm.etch(registry, address(new OfficialVersion(true)).code);
        vm.etch(forwarder, address(new OfficialVersion(false)).code);
        address usdc = DeployMerkleMainnetHarness(_script).USDC();
        vm.etch(usdc, address(new TestnetToken("USDC", "USDC", 6, address(this))).code);
        address factory = DeployMerkleMainnetHarness(_script).VAULT_FACTORY();
        vm.etch(factory, hex"00");
        vm.etch(DeployMerkleMainnetHarness(_script).THREE_F_REQUESTS_FACTORY(), hex"00");
        vm.etch(DeployMerkleMainnetHarness(_script).THREE_F_FACILITY(), hex"00");
        vm.etch(DeployMerkleMainnetHarness(_script).THREE_F_WHITELIST(), hex"00");
        vm.setEnv("MERKLE_MANIFEST", MANIFEST);
        vm.setEnv("MERKLE_PROVIDER", vm.toString(_provider));
        vm.setEnv("MERKLE_ROOT_REGISTRY_OWNER", vm.toString(_rootRegistryOwner));
        vm.setEnv("MERKLE_WORKFLOW_REGISTRY_OWNER", vm.toString(_workflowRegistryOwner));
        vm.setEnv("MERKLE_ORACLE_REGISTRY_OWNER", vm.toString(_oracleRegistryOwner));
        vm.setEnv("MERKLE_CAPABILITIES_REGISTRY_OWNER", vm.toString(_capabilitiesRegistryOwner));
        // No per-vault configuration is required or read.
        vm.setEnv("MERKLE_VAULT", "");
        vm.setEnv("MERKLE_CURATOR", "");
        vm.setEnv("MERKLE_ADMIN", "");
        vm.setEnv("MERKLE_LL_ADAPTER_FACTORY", vm.toString(_llFactory));
        vm.setEnv("MERKLE_LL_REACTOR", vm.toString(_llFactory));
        vm.setEnv("MERKLE_LL_PROTOCOL", vm.toString(makeAddr("protocol signer")));
        if (vm.exists(MANIFEST)) vm.removeFile(MANIFEST);
    }

    function test_ExportsCompleteDeploymentAndGovernanceCalls() public {
        IDeployMerkleAdapter.Deployment memory deployed = DeployMerkleMainnetHarness(_script).run();
        string memory json = vm.readFile(MANIFEST);
        assertEq(vm.parseJsonUint(json, ".chainId"), 1);
        assertEq(vm.parseJsonAddress(json, ".forwarder"), OfficialCRE.MAINNET_FORWARDER);
        assertEq(vm.parseJsonAddress(json, ".chainlinkRegistry"), OfficialCRE.MAINNET_REGISTRY);
        assertEq(vm.parseJsonAddress(json, ".deployment.merkleAdapterFactory"), deployed.adapterFactory);
        assertEq(Ownable(deployed.rootRegistry).owner(), _rootRegistryOwner);
        assertEq(Ownable(deployed.workflowRegistry).owner(), _workflowRegistryOwner);
        assertEq(Ownable(vm.parseJsonAddress(json, ".oracleRegistry")).owner(), _oracleRegistryOwner);
        assertEq(Ownable(deployed.capabilitiesRegistry).owner(), _capabilitiesRegistryOwner);
        assertEq(vm.parseJsonAddress(json, ".rootRegistryOwner"), _rootRegistryOwner);
        assertEq(vm.parseJsonAddress(json, ".workflowRegistryOwner"), _workflowRegistryOwner);
        assertEq(vm.parseJsonAddress(json, ".oracleRegistryOwner"), _oracleRegistryOwner);
        assertEq(vm.parseJsonAddress(json, ".capabilitiesRegistryOwner"), _capabilitiesRegistryOwner);
        address capability = vm.parseJsonAddress(json, ".deployment.recipeCapability");
        assertEq(capability.code, type(RecipeCapability).runtimeCode);
        assertFalse(vm.keyExistsJson(json, ".recipeCapabilityFactory"));
        assertFalse(vm.keyExistsJson(json, ".deployment.claimReadiness"));
        assertEq(vm.parseJsonAddress(json, ".deployment.liquidLane.connectorFactory"), _llFactory);
        address policyFactory = vm.parseJsonAddress(json, ".deployment.threeF.policyFactory");
        address implementation = MigratablesFactory(policyFactory).implementation(1);
        assertEq(
            ThreeFPolicy(implementation).REQUESTS_FACTORY(),
            DeployMerkleMainnetHarness(_script).THREE_F_REQUESTS_FACTORY()
        );
        assertEq(ThreeFPolicy(implementation).FACILITY(), DeployMerkleMainnetHarness(_script).THREE_F_FACILITY());
        assertEq(Ownable(policyFactory).owner(), _provider);
        address connector = vm.parseJsonAddress(json, ".connectorImplementation");
        assertEq(LiquidLaneConnector(connector).MERKLE_ACCOUNT_FACTORY(), deployed.accountFactory);
        assertEq(LiquidLaneConnector(connector).FACTORY(), _llFactory);
        assertEq(MigratablesFactory(_llFactory).lastVersion(), 0);
        assertEq(deployed.adapter, address(0));
        assertFalse(vm.keyExistsJson(json, ".vault"));
        assertFalse(vm.keyExistsJson(json, ".account"));
        assertFalse(vm.keyExistsJson(json, ".oracle"));
        assertFalse(vm.keyExistsJson(json, ".capabilityRegistration"));
        address[3] memory factories = [deployed.adapterFactory, deployed.accountFactory, deployed.oracleFactory];
        for (uint256 i; i < factories.length; ++i) {
            assertEq(MigratablesFactory(factories[i]).totalEntities(), 0);
            assertEq(MigratablesFactory(factories[i]).lastVersion(), 1);
            assertEq(Ownable(factories[i]).owner(), _provider);
        }
        address oracleImplementation = MigratablesFactory(deployed.oracleFactory).implementation(1);
        assertEq(CREOracle(oracleImplementation).FORWARDER(), OfficialCRE.MAINNET_FORWARDER);
        assertEq(CREOracle(oracleImplementation).WORKFLOW_REGISTRY(), deployed.workflowRegistry);
        address accountImplementation = MigratablesFactory(deployed.accountFactory).implementation(1);
        assertEq(MerkleAccount(payable(accountImplementation)).MERKLE_ADAPTER_FACTORY(), deployed.adapterFactory);
        (bool registered,) = _llFactory.call(vm.parseJsonBytes(json, ".connectorRegistration.data"));
        assertTrue(registered);
        assertEq(MigratablesFactory(_llFactory).implementation(1), connector);
        vm.removeFile(MANIFEST);
    }

    function test_RejectsSepoliaBeforeDeploying() public {
        vm.chainId(11_155_111);
        vm.expectRevert(OfficialCRE.InvalidCRE.selector);
        DeployMerkleMainnetHarness(_script).run();
    }

    function test_RejectsMockForwarderBeforeDeploying() public {
        vm.etch(OfficialCRE.MAINNET_FORWARDER, hex"00");
        vm.expectRevert(OfficialCRE.InvalidCRE.selector);
        DeployMerkleMainnetHarness(_script).run();
    }

    function test_RejectsZeroProvider() public {
        vm.setEnv("MERKLE_PROVIDER", vm.toString(address(0)));
        vm.expectRevert(DeployMerkleMainnetScript.InvalidMainnetDependency.selector);
        DeployMerkleMainnetHarness(_script).run();
        vm.setEnv("MERKLE_PROVIDER", vm.toString(_provider));
    }

    function test_RejectsZeroRegistryOwners() public {
        string[4] memory names = [
            "MERKLE_ROOT_REGISTRY_OWNER",
            "MERKLE_WORKFLOW_REGISTRY_OWNER",
            "MERKLE_ORACLE_REGISTRY_OWNER",
            "MERKLE_CAPABILITIES_REGISTRY_OWNER"
        ];
        for (uint256 i; i < names.length; ++i) {
            string memory owner = vm.envString(names[i]);
            vm.setEnv(names[i], vm.toString(address(0)));
            vm.expectRevert(DeployMerkleMainnetScript.InvalidMainnetDependency.selector);
            DeployMerkleMainnetHarness(_script).run();
            assertFalse(vm.exists(MANIFEST));
            vm.setEnv(names[i], owner);
        }
    }

    function test_RequiresExplicitRegistryOwners() public {
        string[4] memory names = [
            "MERKLE_ROOT_REGISTRY_OWNER",
            "MERKLE_WORKFLOW_REGISTRY_OWNER",
            "MERKLE_ORACLE_REGISTRY_OWNER",
            "MERKLE_CAPABILITIES_REGISTRY_OWNER"
        ];
        for (uint256 i; i < names.length; ++i) {
            string memory owner = vm.envString(names[i]);
            vm.setEnv(names[i], "");
            vm.expectRevert();
            DeployMerkleMainnetHarness(_script).run();
            assertFalse(vm.exists(MANIFEST));
            vm.setEnv(names[i], owner);
        }
    }

    function test_RejectsMissingOfficialDependency() public {
        vm.etch(DeployMerkleMainnetHarness(_script).THREE_F_FACILITY(), "");
        vm.expectRevert(DeployMerkleMainnetScript.InvalidMainnetDependency.selector);
        DeployMerkleMainnetHarness(_script).run();
    }

    function test_PreservesExistingManifest() public {
        vm.writeFile(MANIFEST, "existing deployment");
        vm.expectRevert(DeployMerkleMainnetScript.ManifestAlreadyExists.selector);
        DeployMerkleMainnetHarness(_script).run();
        assertEq(vm.readFile(MANIFEST), "existing deployment");
        vm.removeFile(MANIFEST);
    }
}
