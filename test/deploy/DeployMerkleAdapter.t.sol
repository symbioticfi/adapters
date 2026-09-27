// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ORACLE_LIMIT_PRECISION} from "src/interfaces/merkle-adapter/oracle/ICREOracleBase.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {DeployMerkleAdapterScript} from "script/deploy/adapters/DeployMerkleAdapter.s.sol";
import {IDeployMerkleAdapter} from "script/deploy/adapters/interfaces/IDeployMerkleAdapter.sol";

import {KeystoneForwarder} from "test/mocks/chainlink-cre/KeystoneForwarder.sol";
import {
    MerkleAdapterVaultRegistry,
    MerkleAdapterVaultMock,
    MerkleAdapterDelegatorMock
} from "test/adapters/MerkleAdapter.t.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";
import {Token} from "test/mocks/Token.sol";

contract DeployMerkleAdapterHarness is DeployMerkleAdapterScript {
    function _startBroadcast() internal override {}

    function _stopBroadcast() internal override {}

    function _scriptOwner() internal view override returns (address) {
        return address(this);
    }
}

contract DeployMerkleAdapterTest is CREOracleTestBase {
    address internal _script;
    address internal _curator;
    address internal _admin;
    IDeployMerkleAdapter.Config internal _config;
    IDeployMerkleAdapter.Deployment internal _deployed;

    function setUp() public override {
        vm.warp(10_000);
        vm.roll(500);
        _deployChainlinkRegistry();
        forwarder = new KeystoneForwarder();
        address[] memory signers = new address[](4);
        for (uint256 i; i < signers.length; ++i) {
            signers[i] = vm.addr(i + 1);
        }
        forwarder.setConfig(1, 1, 1, signers);
        asset = new Token("Asset");
        address vault = address(new MerkleAdapterVaultMock(address(asset)));
        delegator = new MerkleAdapterDelegatorMock(vault);
        MerkleAdapterVaultMock(vault).setDelegator(address(delegator));
        address vaultFactory = address(new MerkleAdapterVaultRegistry());
        MerkleAdapterVaultRegistry(vaultFactory).add(vault);
        _curator = makeAddr("curator");
        _admin = makeAddr("role admin");
        _script = address(new DeployMerkleAdapterHarness());
        _config = IDeployMerkleAdapter.Config({
            vaultFactory: vaultFactory,
            vault: vault,
            provider: address(this),
            curator: _curator,
            admin: _admin,
            chainlinkWorkflowRegistry: address(chainlinkRegistry),
            maxReportAge: 100,
            maxOracleAge: 1 days,
            reportInterval: 100,
            oracleParams: ICREOracle.InitParams({
                forwarder: address(forwarder),
                defaultAdminRoleHolder: makeAddr("oracle admin"),
                oracleGuardRoleHolder: makeAddr("oracle guard"),
                oracleLimitsRoleHolder: makeAddr("oracle limits"),
                maxOracleGrowth: 12_300,
                maxOracleLoss: 45_600,
                oracleTolerance: 0
            })
        });
        _deployed = DeployMerkleAdapterHarness(_script).runBase(_config);
        workflowRegistry = CREWorkflowRegistry(_deployed.workflowRegistry);
        adapter = MerkleAdapter(payable(_deployed.adapter));
        account = adapter.account();
        oracle = CREOracle(adapter.oracle());
        factory = MigratablesFactory(_deployed.oracleFactory);
    }

    function test_SeparateAuthoritiesAndInactiveBootstrap() public {
        assertEq(Ownable(_deployed.rootRegistry).owner(), address(this));
        assertEq(Ownable(_deployed.capabilitiesRegistry).owner(), address(this));
        assertEq(Ownable(_deployed.adapterFactory).owner(), address(this));
        assertEq(Ownable(_deployed.accountFactory).owner(), address(this));
        assertEq(factory.owner(), address(this));
        assertEq(workflowRegistry.owner(), address(this));
        assertEq(workflowRegistry.CHAINLINK_WORKFLOW_REGISTRY(), address(chainlinkRegistry));
        assertEq(oracle.WORKFLOW_REGISTRY(), address(workflowRegistry));
        assertFalse(chainlinkRegistry.isOwnerLinked(address(workflowRegistry)));
        assertEq(adapter.owner(), _curator);
        assertEq(Ownable(account).owner(), _curator);
        assertEq(IMerkleAccount(account).MERKLE_ADAPTER_FACTORY(), _deployed.adapterFactory);
        assertEq(oracle.owner(), _curator);
        assertEq(IMerkleAccount(account).getRoleMemberCount(bytes32(0)), 1);
        assertTrue(IMerkleAccount(account).hasRole(bytes32(0), _admin));
        assertFalse(IMerkleAccount(account).hasRole(bytes32(0), _script));
        assertEq(IMerkleAccount(account).root(), bytes32(0));
        assertEq(oracle.workflowId(), bytes32(0));
        assertEq(oracle.snapshotBlock(), 0);
        vm.expectRevert(ICREOracle.OracleStale.selector);
        adapter.totalAssets();
    }

    function test_RealBroadcastContextLeavesNoOriginAuthority() public {
        DeployMerkleAdapterScript script = new DeployMerkleAdapterScript();
        address origin = tx.origin;
        assertTrue(origin != _config.provider && origin != _curator && origin != _admin);
        address expectedRootRegistry = vm.computeCreateAddress(origin, vm.getNonce(origin));

        // Exercise the production broadcast and caller-resolution hooks without harness overrides.
        IDeployMerkleAdapter.Deployment memory deployed = script.runBase(_config);
        assertEq(deployed.rootRegistry, expectedRootRegistry);
        address deployedAccount = IMerkleAdapter(deployed.adapter).account();
        CREOracle deployedOracle = CREOracle(IMerkleAdapter(deployed.adapter).oracle());
        assertEq(Ownable(deployed.rootRegistry).owner(), _config.provider);
        assertEq(Ownable(deployed.capabilitiesRegistry).owner(), _config.provider);
        assertEq(Ownable(deployed.adapterFactory).owner(), _config.provider);
        assertEq(Ownable(deployed.accountFactory).owner(), _config.provider);
        assertEq(Ownable(deployed.oracleFactory).owner(), _config.provider);
        assertEq(Ownable(deployed.adapter).owner(), _curator);
        assertEq(Ownable(deployedAccount).owner(), _curator);
        assertEq(IMerkleAccount(deployedAccount).MERKLE_ADAPTER_FACTORY(), deployed.adapterFactory);
        assertEq(deployedOracle.owner(), _curator);
        assertEq(deployedOracle.MAX_ORACLE_AGE(), _config.maxOracleAge);
        assertEq(deployedOracle.getRoleMemberCount(bytes32(0)), 1);
        assertTrue(deployedOracle.hasRole(bytes32(0), _config.oracleParams.defaultAdminRoleHolder));
        assertFalse(deployedOracle.hasRole(bytes32(0), _curator));
        assertFalse(deployedOracle.hasRole(bytes32(0), _admin));
        assertFalse(deployedOracle.hasRole(bytes32(0), origin));
        assertFalse(deployedOracle.hasRole(bytes32(0), address(script)));
        assertEq(IMerkleAccount(deployedAccount).getRoleMemberCount(bytes32(0)), 1);
        assertTrue(IMerkleAccount(deployedAccount).hasRole(bytes32(0), _admin));
        assertFalse(IMerkleAccount(deployedAccount).hasRole(bytes32(0), origin));
        assertFalse(IMerkleAccount(deployedAccount).hasRole(bytes32(0), address(script)));
        assertEq(deployedOracle.getRoleMemberCount(keccak256("ORACLE_GUARD_ROLE")), 1);
        assertEq(deployedOracle.getRoleMemberCount(keccak256("ORACLE_LIMITS_ROLE")), 1);
        assertTrue(deployedOracle.hasRole(keccak256("ORACLE_GUARD_ROLE"), _config.oracleParams.oracleGuardRoleHolder));
        assertTrue(deployedOracle.hasRole(keccak256("ORACLE_LIMITS_ROLE"), _config.oracleParams.oracleLimitsRoleHolder));
        assertEq(deployedOracle.maxOracleGrowth(), _config.oracleParams.maxOracleGrowth);
        assertEq(deployedOracle.maxOracleLoss(), _config.oracleParams.maxOracleLoss);

        vm.startPrank(origin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, origin));
        Ownable(deployed.accountFactory).transferOwnership(origin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, origin));
        IMerkleAccount(deployedAccount).acceptRoot(bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, origin, bytes32(0))
        );
        IMerkleAccount(deployedAccount).grantRole(keccak256("ORACLE_GUARD_ROLE"), origin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, origin, bytes32(0))
        );
        deployedOracle.grantRole(keccak256("ORACLE_GUARD_ROLE"), origin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, origin));
        CREWorkflowRegistry(deployed.workflowRegistry)
            .proposeWorkflow(address(deployedOracle), WORKFLOW, _workflowParams());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, origin, keccak256("ORACLE_GUARD_ROLE")
            )
        );
        deployedOracle.freezeOracle();
        vm.stopPrank();
    }

    function test_ProviderProposalOracleOwnerAcceptanceAndSignedBootstrap() public {
        _linkWorkflowRegistry(keccak256("deployed registry ownership proof"));
        _proposeWorkflow(address(oracle), WORKFLOW);
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        _acceptWorkflow(address(oracle), WORKFLOW);
        vm.prank(_curator);
        _acceptWorkflow(address(oracle), WORKFLOW);
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(workflowRegistry));
        _deliver(_report(0));
        assertEq(oracle.snapshotBlock(), block.number - 1);
        assertEq(adapter.totalAssets(), 0);

        vm.prank(_config.oracleParams.oracleGuardRoleHolder);
        oracle.freezeOracle();
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        adapter.totalAssets();
        vm.prank(_config.oracleParams.oracleGuardRoleHolder);
        oracle.unfreezeOracle(bytes(""));
        assertEq(adapter.totalAssets(), 0);
    }

    function test_RootAndLeafRoleEnablePushAndPull() public {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = IMerkleAccount.Action({
            target: address(adapter),
            value: 0,
            data: abi.encodeCall(IMerkleAdapter.push, (42)),
            dataMask: new bytes(36),
            proof: new bytes32[](0)
        });
        bytes32 leaf = MerkleAdapterVerifier.leaf(actions[0].target, 0, actions[0].data, actions[0].dataMask);
        RootRegistry(_deployed.rootRegistry).setRoot(account, leaf);
        vm.prank(_curator);
        IMerkleAccount(account).acceptRoot(leaf);
        vm.prank(_admin);
        IMerkleAccount(account).grantRole(leaf, _curator);
        deal(address(asset), address(adapter), 42);
        vm.prank(_curator);
        IMerkleAccount(account).manage(actions);
        assertEq(asset.balanceOf(account), 42);
        assertEq(asset.balanceOf(address(adapter)), 0);

        actions[0].data = abi.encodeCall(IMerkleAdapter.pull, (42));
        leaf = MerkleAdapterVerifier.leaf(actions[0].target, 0, actions[0].data, actions[0].dataMask);
        RootRegistry(_deployed.rootRegistry).setRoot(account, leaf);
        vm.prank(_curator);
        IMerkleAccount(account).acceptRoot(leaf);
        vm.prank(_admin);
        IMerkleAccount(account).grantRole(leaf, _curator);
        vm.prank(_curator);
        IMerkleAccount(account).manage(actions);
        assertEq(asset.balanceOf(account), 0);
        assertEq(asset.balanceOf(address(adapter)), 42);
    }

    function test_EnvironmentUsesScaledMovementLimits() public {
        vm.setEnv("MERKLE_VAULT_FACTORY", vm.toString(_config.vaultFactory));
        vm.setEnv("MERKLE_VAULT", vm.toString(_config.vault));
        vm.setEnv("MERKLE_PROVIDER", vm.toString(_config.provider));
        vm.setEnv("MERKLE_CURATOR", vm.toString(_config.curator));
        vm.setEnv("MERKLE_ADMIN", vm.toString(_config.admin));
        vm.setEnv("MERKLE_FORWARDER", vm.toString(_config.oracleParams.forwarder));
        vm.setEnv("MERKLE_CHAINLINK_WORKFLOW_REGISTRY", vm.toString(_config.chainlinkWorkflowRegistry));
        vm.setEnv("MERKLE_MAX_REPORT_AGE", vm.toString(_config.maxReportAge));
        vm.setEnv("MERKLE_MAX_ORACLE_AGE", vm.toString(_config.maxOracleAge));
        vm.setEnv("MERKLE_REPORT_INTERVAL", vm.toString(_config.reportInterval));
        vm.setEnv("MERKLE_ORACLE_ADMIN", vm.toString(_config.oracleParams.defaultAdminRoleHolder));
        vm.setEnv("MERKLE_ORACLE_GUARD", vm.toString(_config.oracleParams.oracleGuardRoleHolder));
        vm.setEnv("MERKLE_ORACLE_LIMITS", vm.toString(_config.oracleParams.oracleLimitsRoleHolder));
        vm.setEnv("MERKLE_MAX_ORACLE_GROWTH", vm.toString(_config.oracleParams.maxOracleGrowth));
        vm.setEnv("MERKLE_MAX_ORACLE_LOSS", vm.toString(_config.oracleParams.maxOracleLoss));
        vm.setEnv("MERKLE_ORACLE_TOLERANCE", vm.toString(_config.oracleParams.oracleTolerance));

        IDeployMerkleAdapter.Deployment memory deployed = DeployMerkleAdapterHarness(_script).run();
        CREOracle deployedOracle = CREOracle(IMerkleAdapter(deployed.adapter).oracle());
        assertEq(deployedOracle.maxOracleGrowth(), 12_300);
        assertEq(deployedOracle.maxOracleLoss(), 45_600);
    }

    function test_AcceptsOracleLimitsAtPrecision() public {
        _config.oracleParams.maxOracleGrowth = ORACLE_LIMIT_PRECISION;
        _config.oracleParams.maxOracleLoss = ORACLE_LIMIT_PRECISION;
        IDeployMerkleAdapter.Deployment memory deployed = DeployMerkleAdapterHarness(_script).runBase(_config);
        CREOracle deployedOracle = CREOracle(IMerkleAdapter(deployed.adapter).oracle());
        assertEq(deployedOracle.maxOracleGrowth(), ORACLE_LIMIT_PRECISION);
        assertEq(deployedOracle.maxOracleLoss(), ORACLE_LIMIT_PRECISION);
    }

    function test_RejectsOracleLimitsAbovePrecisionBeforeDeployment() public {
        uint256 previousGrowth = _config.oracleParams.maxOracleGrowth;
        _config.oracleParams.maxOracleGrowth = ORACLE_LIMIT_PRECISION + 1;
        vm.expectRevert("invalid oracle limits");
        DeployMerkleAdapterHarness(_script).runBase(_config);

        _config.oracleParams.maxOracleGrowth = previousGrowth;
        _config.oracleParams.maxOracleLoss = ORACLE_LIMIT_PRECISION + 1;
        vm.expectRevert("invalid oracle limits");
        DeployMerkleAdapterHarness(_script).runBase(_config);
    }

    function test_RejectsMissingAuthorityBeforeDeployment() public {
        _config.admin = address(0);
        vm.expectRevert("zero authority");
        DeployMerkleAdapterHarness(_script).runBase(_config);
    }

    function test_RejectsUnregisteredVaultBeforeDeployment() public {
        _config.vault = makeAddr("not a registered vault");
        vm.expectRevert("unregistered vault");
        DeployMerkleAdapterHarness(_script).runBase(_config);
    }

    function test_RejectsUnavailableForwarderBeforeDeployment() public {
        _config.oracleParams.forwarder = makeAddr("no forwarder code");
        vm.expectRevert("invalid oracle configuration");
        DeployMerkleAdapterHarness(_script).runBase(_config);
    }

    function test_RejectsZeroReportAgeBeforeDeployment() public {
        _config.maxReportAge = 0;
        vm.expectRevert("invalid oracle configuration");
        DeployMerkleAdapterHarness(_script).runBase(_config);
    }
}
