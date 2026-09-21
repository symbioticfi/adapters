// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {Oracle} from "src/contracts/merkle-adapter/oracle/Oracle.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IOracle} from "src/interfaces/merkle-adapter/oracle/IOracle.sol";

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
import {OracleTestBase} from "test/adapters/merkle-adapter/oracle/Oracle.t.sol";
import {Token} from "test/mocks/Token.sol";

contract DeployMerkleAdapterHarness is DeployMerkleAdapterScript {
    function _startBroadcast() internal override {}

    function _stopBroadcast() internal override {}

    function _scriptOwner() internal view override returns (address) {
        return address(this);
    }
}

contract DeployMerkleAdapterTest is OracleTestBase {
    address internal _script;
    address internal _curator;
    address internal _admin;
    IDeployMerkleAdapter.Config internal _config;
    IDeployMerkleAdapter.Deployment internal _deployed;

    function setUp() public override {
        vm.warp(10_000);
        vm.roll(500);
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
            forwarder: address(forwarder),
            maxReportAge: 100,
            reportInterval: 100,
            reportBuffer: 10
        });
        _deployed = DeployMerkleAdapterHarness(_script).runBase(_config);
        adapter = MerkleAdapter(payable(_deployed.adapter));
        account = adapter.account();
        oracle = Oracle(adapter.oracle());
        factory = MigratablesFactory(_deployed.oracleFactory);
    }

    function test_SeparateAuthoritiesAndInactiveBootstrap() public {
        assertEq(Ownable(_deployed.rootRegistry).owner(), address(this));
        assertEq(Ownable(_deployed.capabilitiesRegistry).owner(), address(this));
        assertEq(Ownable(_deployed.adapterFactory).owner(), address(this));
        assertEq(Ownable(_deployed.accountFactory).owner(), address(this));
        assertEq(factory.owner(), address(this));
        assertEq(adapter.owner(), _curator);
        assertEq(Ownable(account).owner(), _curator);
        assertEq(oracle.owner(), _curator);
        assertEq(IMerkleAccount(account).getRoleMemberCount(bytes32(0)), 1);
        assertTrue(IMerkleAccount(account).hasRole(bytes32(0), _admin));
        assertFalse(IMerkleAccount(account).hasRole(bytes32(0), _script));
        assertEq(IMerkleAccount(account).merkleRoot(), bytes32(0));
        assertEq(oracle.workflowId(), bytes32(0));
        assertEq(oracle.nonce(), 0);
        vm.expectRevert(IOracle.OracleStale.selector);
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
        Oracle deployedOracle = Oracle(IMerkleAdapter(deployed.adapter).oracle());
        assertEq(Ownable(deployed.rootRegistry).owner(), _config.provider);
        assertEq(Ownable(deployed.capabilitiesRegistry).owner(), _config.provider);
        assertEq(Ownable(deployed.adapterFactory).owner(), _config.provider);
        assertEq(Ownable(deployed.accountFactory).owner(), _config.provider);
        assertEq(Ownable(deployed.oracleFactory).owner(), _config.provider);
        assertEq(Ownable(deployed.adapter).owner(), _curator);
        assertEq(Ownable(deployedAccount).owner(), _curator);
        assertEq(deployedOracle.owner(), _curator);
        assertEq(IMerkleAccount(deployedAccount).getRoleMemberCount(bytes32(0)), 1);
        assertTrue(IMerkleAccount(deployedAccount).hasRole(bytes32(0), _admin));
        assertFalse(IMerkleAccount(deployedAccount).hasRole(bytes32(0), origin));
        assertFalse(IMerkleAccount(deployedAccount).hasRole(bytes32(0), address(script)));
        assertEq(IMerkleAccount(deployedAccount).getRoleMemberCount(keccak256("ORACLE_GUARD_ROLE")), 0);
        assertEq(IMerkleAccount(deployedAccount).getRoleMemberCount(keccak256("ORACLE_LIMITS_ROLE")), 0);
        assertEq(IMerkleAccount(deployedAccount).getRoleMemberCount(keccak256("ORACLE_AGE_ROLE")), 0);

        vm.startPrank(origin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, origin));
        Ownable(deployed.accountFactory).transferOwnership(origin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, origin));
        IMerkleAccount(deployedAccount).acceptRoot(bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, origin, bytes32(0))
        );
        IMerkleAccount(deployedAccount).grantRole(keccak256("ORACLE_GUARD_ROLE"), origin);
        vm.expectRevert(IOracle.InvalidCaller.selector);
        deployedOracle.proposeWorkflow(WORKFLOW);
        vm.expectRevert(IOracle.InvalidCaller.selector);
        deployedOracle.freezeOracle();
        vm.stopPrank();
    }

    function test_ProviderProposalCuratorAcceptanceAndSignedBootstrap() public {
        oracle.proposeWorkflow(WORKFLOW);
        vm.expectRevert(IOracle.InvalidCaller.selector);
        oracle.acceptWorkflow(WORKFLOW);
        vm.prank(_curator);
        oracle.acceptWorkflow(WORKFLOW);
        _deliver(_report(0));
        assertEq(oracle.nonce(), 1);
        assertEq(adapter.totalAssets(), 0);

        vm.prank(_admin);
        IMerkleAccount(account).grantRole(keccak256("ORACLE_GUARD_ROLE"), _curator);
        vm.prank(_curator);
        oracle.freezeOracle();
        vm.expectRevert(IOracle.OracleFrozen.selector);
        adapter.totalAssets();
        vm.prank(_curator);
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
        _config.forwarder = makeAddr("no forwarder code");
        vm.expectRevert("invalid oracle configuration");
        DeployMerkleAdapterHarness(_script).runBase(_config);
    }

    function test_RejectsZeroReportAgeBeforeDeployment() public {
        _config.maxReportAge = 0;
        vm.expectRevert("invalid oracle configuration");
        DeployMerkleAdapterHarness(_script).runBase(_config);
    }
}
