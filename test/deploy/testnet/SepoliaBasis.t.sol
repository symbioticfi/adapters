// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AccountRegistry} from "src/contracts/ll-adapter/AccountRegistry.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {LiquidLaneConnector} from "src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";

import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";

import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {DeploySepoliaBasisScript} from "script/deploy/testnet/DeploySepoliaBasis.s.sol";
import {DeploySepoliaCRERegistrationScript} from "script/deploy/testnet/DeploySepoliaCRERegistration.s.sol";
import {OfficialCRE} from "script/deploy/merkle/OfficialCRE.sol";
import {SepoliaCRE} from "script/deploy/testnet/protocols/SepoliaCRE.sol";
import {SepoliaInfrastructure} from "script/deploy/testnet/SepoliaInfrastructure.sol";
import {TestnetCatalog} from "script/deploy/testnet/catalog/TestnetCatalog.sol";
import {TestnetToken} from "script/deploy/testnet/protocols/TestnetAssets.sol";

import {KeystoneForwarder} from "test/mocks/chainlink-cre/KeystoneForwarder.sol";
import {TestnetCreate2Factory} from "test/helpers/TestnetCreate2Factory.sol";
import {WorkflowRegistry} from "test/mocks/chainlink-cre/WorkflowRegistry.sol";

contract SepoliaBasisHarness is DeploySepoliaBasisScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract SepoliaBasisTest is Test {
    string internal constant MANIFEST = "cache/sepolia-basis-test.json";
    address internal _owner;
    address internal _script;

    function setUp() public {
        vm.chainId(SepoliaInfrastructure.CHAIN_ID);
        vm.roll(1000);
        vm.warp(1_800_000_000);
        _owner = makeAddr("basis owner");
        _script = address(new SepoliaBasisHarness());
        vm.etch(SepoliaCRE.CREATE2_DEPLOYER, address(new TestnetCreate2Factory()).code);
        address usdc = address(new TestnetToken("USDC", "USDC", 6, _owner));
        vm.etch(SepoliaInfrastructure.USDC, usdc.code);
        vm.copyStorage(usdc, SepoliaInfrastructure.USDC);
        vm.etch(SepoliaInfrastructure.FORWARDER, address(new KeystoneForwarder()).code);
        vm.etch(SepoliaInfrastructure.REQUESTS_FACTORY, hex"00");
        vm.mockCall(
            SepoliaInfrastructure.REQUESTS_FACTORY,
            abi.encodeWithSelector(IThreeFRequestFactory.isRequest.selector),
            abi.encode(false)
        );
        vm.etch(SepoliaInfrastructure.FACILITY, hex"00");
        vm.etch(SepoliaInfrastructure.WHITELIST, hex"00");
        if (vm.exists(MANIFEST)) vm.removeFile(MANIFEST);
    }

    function test_ExportsEmptyInfrastructureAndVenueBasisWithoutPortfolioInstances() public {
        string memory previousOwner = vm.envOr("TESTNET_OWNER", string(""));
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        vm.setEnv("TESTNET_OWNER", vm.toString(_owner));
        vm.setEnv("TESTNET_MANIFEST", MANIFEST);
        vm.startStateDiffRecording();
        DeploySepoliaBasisScript.Deployment memory deployed = SepoliaBasisHarness(_script).run();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        vm.setEnv("TESTNET_OWNER", previousOwner);
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
        uint256 transactions;
        for (uint256 i; i < accesses.length; ++i) {
            if (
                accesses[i].accessor == _owner
                    && (accesses[i].kind == VmSafe.AccountAccessKind.Call
                        || accesses[i].kind == VmSafe.AccountAccessKind.Create)
            ) {
                assertFalse(accesses[i].reverted);
                assertEq(accesses[i].value, 0);
                ++transactions;
            }
        }
        emit log_named_uint("Sepolia basis transaction count", transactions);
        DeployRealisticTestnetScript.Deployment memory basis = deployed.basis;
        address[8] memory factories = [
            basis.vaultFactory,
            basis.universalDelegatorFactory,
            basis.withdrawalQueueFactory,
            deployed.merkle.adapterFactory,
            deployed.merkle.accountFactory,
            deployed.merkle.oracleFactory,
            deployed.connectorFactory,
            deployed.policyFactory
        ];
        for (uint256 i; i < factories.length; ++i) {
            assertEq(IRegistry(factories[i]).totalEntities(), 0);
            assertEq(Ownable(factories[i]).owner(), _owner);
        }
        for (uint256 i; i < deployed.adapterFactories.length; ++i) {
            assertEq(IRegistry(deployed.adapterFactories[i]).totalEntities(), 0);
            assertEq(Ownable(deployed.adapterFactories[i]).owner(), _owner);
        }
        assertEq(MigratablesFactory(basis.vaultFactory).lastVersion(), 3);
        assertEq(IRegistry(basis.networkRegistry).totalEntities(), 0);
        assertEq(IRegistry(basis.operatorRegistry).totalEntities(), 0);
        assertEq(deployed.merkle.adapter, address(0));
        assertEq(CREWorkflowRegistry(deployed.merkle.workflowRegistry).owner(), _owner);
        assertEq(
            CREWorkflowRegistry(deployed.merkle.workflowRegistry).CHAINLINK_WORKFLOW_REGISTRY(), basis.chainlinkRegistry
        );
        assertEq(CREWorkflowRegistry(deployed.merkle.workflowRegistry).workflowId(address(1)), bytes32(0));
        assertEq(
            CREOracle(MigratablesFactory(deployed.merkle.oracleFactory).implementation(1)).FORWARDER(),
            SepoliaInfrastructure.FORWARDER
        );
        assertEq(ThreeFPolicy(deployed.policyImplementation).REQUESTS_FACTORY(), SepoliaInfrastructure.REQUESTS_FACTORY);
        assertEq(ThreeFPolicy(deployed.policyImplementation).FACILITY(), SepoliaInfrastructure.FACILITY);
        assertEq(
            LiquidLaneConnector(deployed.connectorImplementation).MERKLE_ACCOUNT_FACTORY(),
            deployed.merkle.accountFactory
        );
        assertEq(LiquidLaneConnector(deployed.connectorImplementation).ORACLE_REGISTRY(), deployed.oracleRegistry);
        assertEq(MigratablesFactory(deployed.connectorFactory).implementation(2), deployed.connectorImplementation);
        assertEq(IERC20(basis.collateral).totalSupply(), 0);
        assertEq(basis.markets.length, 7);
        uint256 rwaCount;
        for (uint256 i; i < basis.markets.length; ++i) {
            DeployRealisticTestnetScript.Market memory venue = basis.markets[i];
            assertEq(venue.vault, address(0));
            assertEq(venue.restakingVault, address(0));
            assertEq(venue.merkle.adapter, address(0));
            assertEq(venue.executor, address(0));
            assertEq(venue.connector, address(0));
            assertEq(venue.policy, address(0));
            assertEq(venue.request, address(0));
            assertEq(venue.actions.length, 0);
            assertEq(venue.recipe.length, 0);
            assertEq(IERC20(venue.asset).totalSupply(), 0);
            assertEq(IERC20(venue.euler).totalSupply(), 0);
            assertEq(IERC20(venue.morpho).totalSupply(), 0);
            assertEq(IERC20(venue.erc4626).totalSupply(), 0);
            assertGt(venue.assetFeed.code.length, 0);
            for (uint256 j; j < venue.rwas.length; ++j) {
                DeployRealisticTestnetScript.RWA memory rwa = venue.rwas[j];
                ++rwaCount;
                assertEq(MigratablesFactory(rwa.accountFactory).totalEntities(), 0);
                assertEq(MigratablesFactory(rwa.accountFactory).lastVersion(), 1);
                assertEq(IERC20(rwa.token).totalSupply(), 0);
                assertEq(
                    AccountRegistry(deployed.accountRegistry).accountFactories(venue.asset, rwa.token),
                    rwa.accountFactory
                );
            }
        }
        assertEq(rwaCount, TestnetCatalog.count());
        string memory json = vm.readFile(MANIFEST);
        assertEq(vm.parseJsonAddress(json, ".workflowRegistry"), deployed.merkle.workflowRegistry);
        assertEq(vm.parseJsonAddress(json, ".vaultFactory"), basis.vaultFactory);
        assertEq(vm.parseJsonAddress(json, ".venues[0].asset"), SepoliaInfrastructure.USDC);
        assertEq(vm.parseJsonAddress(json, ".rwas[0].accountFactory"), basis.markets[0].rwas[0].accountFactory);
        assertEq(vm.parseJsonAddressArray(json, ".vaults").length, 0);
        assertFalse(vm.keyExistsJson(json, ".markets"));
        assertFalse(vm.keyExistsJson(json, ".account"));
        assertFalse(vm.keyExistsJson(json, ".oracle"));
        vm.removeFile(MANIFEST);
    }

    function test_MainnetRegistrationAcceptsTopLevelWorkflowRegistry() public {
        _registrationManifest(true);
    }

    function test_MainnetRegistrationAcceptsFullStandManifest() public {
        _registrationManifest(false);
    }

    function _registrationManifest(bool topLevel) internal {
        address replica = makeAddr(topLevel ? "basis replica" : "full stand replica");
        uint256 beforePair = vm.snapshotState();
        address expected = SepoliaCRE.deploy(_owner, replica);
        assertTrue(vm.revertToState(beforePair));
        vm.chainId(1);
        vm.etch(OfficialCRE.MAINNET_REGISTRY, address(new WorkflowRegistry()).code);
        vm.etch(OfficialCRE.MAINNET_FORWARDER, address(new KeystoneForwarder()).code);
        string memory key = topLevel ? "basis-registration" : "full-registration";
        vm.serializeUint(key, "chainId", SepoliaInfrastructure.CHAIN_ID);
        vm.serializeAddress(key, "owner", _owner);
        string memory json = vm.serializeAddress(key, "chainlinkRegistry", replica);
        if (topLevel) json = vm.serializeAddress(key, "workflowRegistry", expected);
        vm.writeJson(json, MANIFEST);
        if (!topLevel) {
            string memory row = vm.serializeAddress("registry-row", "workflowRegistry", expected);
            vm.writeJson(string.concat("[", row, "]"), MANIFEST, ".markets");
        }
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        vm.setEnv("TESTNET_MANIFEST", MANIFEST);
        address result = DeploySepoliaCRERegistrationScript(address(new DeploySepoliaCRERegistrationScript())).run();
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
        assertEq(result, expected);
        assertEq(Ownable(result).owner(), _owner);
        assertFalse(WorkflowRegistry(OfficialCRE.MAINNET_REGISTRY).isOwnerLinked(result));
        vm.removeFile(MANIFEST);
    }

    function test_RejectsWrongChainBeforeCreatingCore() public {
        vm.chainId(1);
        vm.expectRevert(DeployRealisticTestnetScript.InvalidConfiguration.selector);
        SepoliaBasisHarness(_script).runBase(_owner);
    }

    function test_RejectsZeroOwnerBeforeCreatingCore() public {
        vm.expectRevert(DeployRealisticTestnetScript.InvalidConfiguration.selector);
        SepoliaBasisHarness(_script).runBase(address(0));
    }

    function test_RejectsMissingOfficialDependencyBeforeCreatingCore() public {
        vm.etch(SepoliaInfrastructure.FORWARDER, "");
        vm.expectRevert(SepoliaInfrastructure.InvalidInfrastructure.selector);
        SepoliaBasisHarness(_script).runBase(_owner);
    }

    function test_PreservesExistingManifest() public {
        string memory previousManifest = vm.envOr("TESTNET_MANIFEST", string(""));
        vm.setEnv("TESTNET_MANIFEST", MANIFEST);
        vm.writeFile(MANIFEST, "existing");
        vm.expectRevert(DeploySepoliaBasisScript.ManifestAlreadyExists.selector);
        SepoliaBasisHarness(_script).run();
        assertEq(vm.readFile(MANIFEST), "existing");
        vm.removeFile(MANIFEST);
        vm.setEnv("TESTNET_MANIFEST", previousManifest);
    }
}
