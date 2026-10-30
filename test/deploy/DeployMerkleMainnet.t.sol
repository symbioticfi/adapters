// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployMerkleMainnetScript} from "script/deploy/merkle/DeployMerkleMainnet.s.sol";
import {OfficialCRE} from "script/deploy/merkle/OfficialCRE.sol";
import {IDeployMerkleAdapter} from "script/deploy/adapters/interfaces/IDeployMerkleAdapter.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";
import {LiquidLaneConnector} from "src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {ICapabilitiesRegistry} from "src/interfaces/merkle-adapter/ICapabilitiesRegistry.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {MerkleAdapterVaultRegistry, MerkleAdapterVaultMock} from "test/adapters/MerkleAdapter.t.sol";
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
    address private _vault;
    address private _llFactory;
    address private _provider;

    function setUp() public {
        vm.chainId(1);
        vm.roll(1000);
        _script = address(new DeployMerkleMainnetHarness());
        _provider = makeAddr("provider");
        _llFactory = address(new MigratablesFactory(address(this)));
        address registry = OfficialCRE.MAINNET_REGISTRY;
        address forwarder = OfficialCRE.MAINNET_FORWARDER;
        vm.etch(registry, address(new OfficialVersion(true)).code);
        vm.etch(forwarder, address(new OfficialVersion(false)).code);
        address usdc = DeployMerkleMainnetHarness(_script).USDC();
        vm.etch(usdc, address(new TestnetToken("USDC", "USDC", 6, address(this))).code);
        _vault = address(new MerkleAdapterVaultMock(usdc));
        address factory = DeployMerkleMainnetHarness(_script).VAULT_FACTORY();
        vm.etch(factory, address(new MerkleAdapterVaultRegistry()).code);
        MerkleAdapterVaultRegistry(factory).add(_vault);
        vm.etch(DeployMerkleMainnetHarness(_script).THREE_F_REQUESTS_FACTORY(), hex"00");
        vm.etch(DeployMerkleMainnetHarness(_script).THREE_F_FACILITY(), hex"00");
        vm.etch(DeployMerkleMainnetHarness(_script).THREE_F_WHITELIST(), hex"00");
        vm.setEnv("MERKLE_MANIFEST", MANIFEST);
        vm.setEnv("MERKLE_VAULT_FACTORY", vm.toString(factory));
        vm.setEnv("MERKLE_VAULT", vm.toString(_vault));
        vm.setEnv("MERKLE_PROVIDER", vm.toString(_provider));
        vm.setEnv("MERKLE_CURATOR", vm.toString(makeAddr("curator")));
        vm.setEnv("MERKLE_ADMIN", vm.toString(makeAddr("admin")));
        vm.setEnv("MERKLE_ORACLE_ADMIN", vm.toString(makeAddr("oracle admin")));
        vm.setEnv("MERKLE_ORACLE_GUARD", vm.toString(makeAddr("oracle guard")));
        vm.setEnv("MERKLE_ORACLE_LIMITS", vm.toString(makeAddr("oracle limits")));
        vm.setEnv("MERKLE_MAX_ORACLE_GROWTH", "100000");
        vm.setEnv("MERKLE_MAX_ORACLE_LOSS", "100000");
        vm.setEnv("MERKLE_ORACLE_TOLERANCE", "0");
        vm.setEnv("MERKLE_CHAINLINK_WORKFLOW_REGISTRY", vm.toString(address(0)));
        vm.setEnv("MERKLE_FORWARDER", vm.toString(address(0)));
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
        address account = IMerkleAdapter(deployed.adapter).account();
        assertEq(
            ICapabilitiesRegistry(deployed.capabilitiesRegistry)
            .selectors(account, vm.parseJsonAddress(json, ".deployment.recipeCapability"))
            .length,
            0
        );
        vm.prank(_provider);
        (bool registered,) = deployed.capabilitiesRegistry.call(vm.parseJsonBytes(json, ".capabilityRegistration.data"));
        assertTrue(registered);
        assertEq(
            ICapabilitiesRegistry(deployed.capabilitiesRegistry)
                .selectors(account, vm.parseJsonAddress(json, ".deployment.recipeCapability"))[0],
            IRecipeCapability.execute.selector
        );
        (registered,) = _llFactory.call(vm.parseJsonBytes(json, ".connectorRegistration.data"));
        assertTrue(registered);
        assertEq(MigratablesFactory(_llFactory).implementation(1), connector);
        assertEq(ICREOracle(IMerkleAdapter(deployed.adapter).oracle()).snapshotBlock(), 0);
        vm.removeFile(MANIFEST);
    }

    function test_RejectsSepoliaBeforeDeploying() public {
        vm.chainId(11_155_111);
        vm.expectRevert(OfficialCRE.InvalidCRE.selector);
        DeployMerkleMainnetHarness(_script).run();
    }

    function test_RejectsMockForwarderBeforeDeploying() public {
        vm.setEnv("MERKLE_FORWARDER", vm.toString(_llFactory));
        vm.expectRevert(OfficialCRE.InvalidCRE.selector);
        DeployMerkleMainnetHarness(_script).run();
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
