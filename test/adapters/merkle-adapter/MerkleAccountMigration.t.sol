// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {Oracle} from "src/contracts/merkle-adapter/oracle/Oracle.sol";

import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IOracle} from "src/interfaces/merkle-adapter/oracle/IOracle.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {MerkleAdapterVaultRegistry} from "test/adapters/MerkleAdapter.t.sol";
import {Token} from "test/mocks/Token.sol";

contract MerkleAccountMigrationTest is CapabilityTestBase {
    address internal _asset;

    function setUp() public {
        _asset = address(new Token("asset"));
        _deployAdapter(_asset);
    }

    function test_AccountIsInitializedMigratableEntity() public view {
        assertEq(IMerkleAccount(account).version(), 1);
        assertEq(IMerkleAccount(account).FACTORY(), adapter.ACCOUNT_FACTORY());
        assertEq(Ownable(account).owner(), adapter.owner());
        assertTrue(IMerkleAccount(account).hasRole(bytes32(0), address(this)));
    }

    function test_AccountApprovesAdapterUnderlying() public view {
        assertEq(IERC20(_asset).allowance(account, address(adapter)), type(uint256).max);
    }

    function test_AccountImplementationAndProxyCannotBeReinitialized() public {
        bytes memory data =
            abi.encode(IMerkleAccount.InitParams({adapter: address(adapter), defaultAdminRoleHolder: address(this)}));
        vm.expectRevert(IMigratableEntity.AlreadyInitialized.selector);
        IMerkleAccount(account).initialize(2, address(this), data);
        address implementation = IMigratablesFactory(adapter.ACCOUNT_FACTORY()).implementation(1);
        vm.expectRevert(IMigratableEntity.AlreadyInitialized.selector);
        IMerkleAccount(implementation).initialize(1, address(this), data);
    }

    function test_CreationUsesLatestVersionAndAdapterOwner() public {
        address factory = adapter.ACCOUNT_FACTORY();
        IMigratablesFactory(factory)
            .whitelist(
                address(new MerkleAccount(factory, address(roots), IMerkleAccount(account).CAPABILITIES_REGISTRY()))
            );
        address vaults = address(new MerkleAdapterVaultRegistry());
        MerkleAdapterVaultRegistry(vaults).add(adapter.vault());
        address adapters = address(new AdapterFactory(address(this)));
        IMigratablesFactory(adapters)
            .whitelist(address(new MerkleAdapter(vaults, adapters, adapter.ORACLE_FACTORY(), factory)));
        address curator = makeAddr("curator");
        address deployed = IMigratablesFactory(adapters)
            .create(
                1,
                curator,
                abi.encode(
                    adapter.vault(), abi.encode(IMerkleAdapter.InitParams({defaultAdminRoleHolder: address(this)}))
                )
            );
        address custody = IMerkleAdapter(deployed).account();
        assertEq(IMerkleAccount(custody).version(), 2);
        assertEq(Ownable(custody).owner(), curator);
        assertEq(IMerkleAccount(custody).adapter(), deployed);
        assertTrue(IMerkleAccount(custody).hasRole(bytes32(0), address(this)));
        assertFalse(IMerkleAccount(custody).hasRole(bytes32(0), curator));
        assertEq(IERC20(_asset).allowance(custody, deployed), type(uint256).max);
        assertEq(IMerkleAccount(account).version(), 1);
    }

    function test_MigrationRequiresAccountOwnerAndPreservesStrategy() public {
        address capability = address(new GuardedCallsCapability());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IGuardedCallsCapability.execute.selector;
        CapabilitiesRegistry(IMerkleAccount(account).CAPABILITIES_REGISTRY())
            .whitelistCapability(account, capability, selectors);
        IMerkleAccount(account).addCapability(capability);
        bytes32 domain = keccak256("test domain");
        bytes memory fields = abi.encode(keccak256("Test(uint256 amount)"), uint256(42));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(fields));
        _manage(account, abi.encodeCall(IMerkleAccount.setSignature, (domain, fields, new IMerkleAccount.Hash[](0))));
        IMerkleAccount.Action[] memory actions =
            _publishCall(address(adapter), abi.encodeCall(IMerkleAdapter.push, (10)));
        bytes32 root = IMerkleAccount(account).merkleRoot();
        deal(_asset, address(adapter), 10);
        address factory = adapter.ACCOUNT_FACTORY();
        IMigratablesFactory(factory)
            .whitelist(
                address(new MerkleAccount(factory, address(roots), IMerkleAccount(account).CAPABILITIES_REGISTRY()))
            );
        vm.expectRevert(IMigratablesFactory.NotOwner.selector);
        vm.prank(makeAddr("not owner"));
        IMigratablesFactory(factory).migrate(account, 2, "");
        vm.expectRevert(IMigratableEntity.NotFactory.selector);
        IMerkleAccount(account).migrate(2, "");
        IMigratablesFactory(factory).migrate(account, 2, "");
        assertEq(IMerkleAccount(account).version(), 2);
        assertEq(IMerkleAccount(account).adapter(), address(adapter));
        assertEq(Ownable(account).owner(), address(this));
        assertEq(IMerkleAccount(account).merkleRoot(), root);
        assertTrue(IMerkleAccount(account).hasRole(root, address(this)));
        assertEq(IMerkleAccount(account).getRoleMemberCount(root), 1);
        assertTrue(IMerkleAccount(account).isCapability(capability));
        assertEq(IMerkleAccount(account).capabilityBySelector(selectors[0]), capability);
        assertEq(IMerkleAccount(account).capabilitySelectors(capability, 0), selectors[0]);
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
        assertEq(IERC20(_asset).allowance(account, address(adapter)), type(uint256).max);
        IMerkleAccount(account).manage(actions);
        assertEq(IERC20(_asset).balanceOf(account), 10);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.pull, (10)));
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 10);
        IGuardedCallsCapability.Call[] memory calls = new IGuardedCallsCapability.Call[](1);
        calls[0] =
            IGuardedCallsCapability.Call({target: _asset, data: abi.encodeCall(IERC20.approve, (address(0xBEEF), 42))});
        _manage(
            account, abi.encodeCall(IGuardedCallsCapability.execute, (calls, new IGuardedCallsCapability.Check[](0)))
        );
        assertEq(IERC20(_asset).allowance(account, address(0xBEEF)), 42);
        IMerkleAccount(account).revokeRole(IMerkleAccount(account).merkleRoot(), address(this));
        assertFalse(IMerkleAccount(account).hasRole(IMerkleAccount(account).merkleRoot(), address(this)));
    }

    function test_MigrationAuthorityFollowsAccountOwnership() public {
        address factory = adapter.ACCOUNT_FACTORY();
        IMigratablesFactory(factory)
            .whitelist(
                address(new MerkleAccount(factory, address(roots), IMerkleAccount(account).CAPABILITIES_REGISTRY()))
            );
        address curator = makeAddr("new account owner");
        MerkleAccount(payable(account)).transferOwnership(curator);
        assertEq(adapter.owner(), address(this));
        vm.expectRevert(IMigratablesFactory.NotOwner.selector);
        IMigratablesFactory(factory).migrate(account, 2, "");
        vm.prank(curator);
        IMigratablesFactory(factory).migrate(account, 2, "");
        assertEq(IMerkleAccount(account).version(), 2);
        assertEq(Ownable(account).owner(), curator);
        assertTrue(IMerkleAccount(account).hasRole(bytes32(0), address(this)));
        assertFalse(IMerkleAccount(account).hasRole(bytes32(0), curator));
    }

    function test_OracleUsesAccountOwnerAndRoles() public {
        address factory = address(new MigratablesFactory(address(this)));
        IMigratablesFactory(factory).whitelist(address(new Oracle(factory, makeAddr("forwarder"), 1 days)));
        address oracle = IMigratablesFactory(factory).create(1, address(this), abi.encode(address(adapter)));
        address curator = makeAddr("new account owner");
        MerkleAccount(payable(account)).transferOwnership(curator);
        bytes32 workflow = keccak256("workflow");
        IOracle(oracle).proposeWorkflow(workflow);
        vm.expectRevert(IOracle.InvalidCaller.selector);
        IOracle(oracle).acceptWorkflow(workflow);
        vm.prank(curator);
        IOracle(oracle).acceptWorkflow(workflow);
        assertEq(IOracle(oracle).workflowId(), workflow);
        assertEq(adapter.owner(), address(this));
        vm.expectRevert(IOracle.InvalidCaller.selector);
        vm.prank(curator);
        IOracle(oracle).freezeOracle();
        IMerkleAccount(account).grantRole(keccak256("ORACLE_GUARD_ROLE"), curator);
        vm.prank(curator);
        IOracle(oracle).freezeOracle();
        assertTrue(IOracle(oracle).oracleFrozen());
    }

    function testFuzz_PullReturnsOnlyRequestedAmount(uint96 balance, uint96 amount) public {
        balance = uint96(bound(balance, 1, 1e24));
        amount = uint96(bound(amount, 0, balance));
        deal(_asset, account, balance);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.pull, (amount)));
        assertEq(IERC20(_asset).balanceOf(account), balance - amount);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), amount);
        assertEq(IERC20(_asset).allowance(account, address(adapter)), type(uint256).max);
    }

    function test_PullRejectsExternalCaller() public {
        deal(_asset, account, 10);
        vm.expectRevert(IMerkleAdapter.InvalidCaller.selector);
        adapter.pull(10);
        assertEq(IERC20(_asset).balanceOf(account), 10);
    }

    /// forge-config: default.isolate = true
    function test_PullGas() public {
        deal(_asset, account, 10);
        vm.prank(account);
        adapter.pull(10);
        vm.snapshotGasLastCall("pull");
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 10);
    }
}
