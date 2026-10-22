// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {OP_CALL} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";
import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {CREWorkflowRegistryTestHelper} from "test/helpers/CREWorkflowRegistry.sol";
import {Token} from "test/mocks/Token.sol";
import {flatPlan} from "test/helpers/HashPlan.sol";
import {merkleAdapterInitParams, defaultOracleInitParams} from "test/helpers/MerkleInitialization.sol";

contract UnregisteredMerkleAdapterMock {
    address public immutable FACTORY;
    address public immutable vault;

    constructor(address factory, address newVault) {
        FACTORY = factory;
        vault = newVault;
    }
}

contract MerkleAccountMigrationTest is CapabilityTestBase, CREWorkflowRegistryTestHelper {
    address internal _asset;

    function setUp() public {
        _asset = address(new Token("asset"));
        _deployAdapter(_asset);
    }

    function test_AccountIsInitializedMigratableEntity() public view {
        assertEq(IMerkleAccount(account).version(), 1);
        assertEq(IMerkleAccount(account).FACTORY(), adapter.ACCOUNT_FACTORY());
        assertEq(IMerkleAccount(account).MERKLE_ADAPTER_FACTORY(), adapter.FACTORY());
        assertTrue(IRegistry(adapter.FACTORY()).isEntity(address(adapter)));
        assertEq(Ownable(account).owner(), adapter.owner());
        assertTrue(IMerkleAccount(account).hasRole(bytes32(0), address(this)));
    }

    function test_AccountApprovesAdapterUnderlying() public view {
        assertEq(IERC20(_asset).allowance(account, address(adapter)), type(uint256).max);
    }

    function test_AccountInitializationRejectsUnregisteredAdapter() public {
        address unregistered = address(new UnregisteredMerkleAdapterMock(adapter.FACTORY(), adapter.vault()));
        assertFalse(IRegistry(adapter.FACTORY()).isEntity(unregistered));
        address factory = adapter.ACCOUNT_FACTORY();
        uint256 count = IRegistry(factory).totalEntities();
        vm.expectRevert(IMerkleAccount.InvalidAdapter.selector);
        IMigratablesFactory(factory)
            .create(
                1,
                address(this),
                abi.encode(unregistered, abi.encode(IMerkleAccount.InitParams({defaultAdminRoleHolder: address(this)})))
            );
        assertEq(IRegistry(factory).totalEntities(), count);
    }

    function test_AccountInitializationRejectsAdapterFromAnotherFactory() public {
        address factory = adapter.ACCOUNT_FACTORY();
        address allowedAdapters = adapter.FACTORY();
        uint256 count = IRegistry(factory).totalEntities();
        _deployAdapter(_asset);
        assertTrue(IRegistry(adapter.FACTORY()).isEntity(address(adapter)));
        assertFalse(IRegistry(allowedAdapters).isEntity(address(adapter)));
        vm.expectRevert(IMerkleAccount.InvalidAdapter.selector);
        IMigratablesFactory(factory)
            .create(
                1,
                address(this),
                abi.encode(
                    address(adapter), abi.encode(IMerkleAccount.InitParams({defaultAdminRoleHolder: address(this)}))
                )
            );
        assertEq(IRegistry(factory).totalEntities(), count);
    }

    function test_AccountImplementationAndProxyCannotBeReinitialized() public {
        bytes memory data = abi.encode(
            address(adapter), abi.encode(IMerkleAccount.InitParams({defaultAdminRoleHolder: address(this)}))
        );
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
                address(
                    new MerkleAccount(
                        factory, adapter.FACTORY(), address(roots), IMerkleAccount(account).CAPABILITIES_REGISTRY()
                    )
                )
            );
        address curator = makeAddr("curator");
        address deployed = IMigratablesFactory(adapter.FACTORY())
            .create(1, curator, abi.encode(adapter.vault(), abi.encode(merkleAdapterInitParams(address(this)))));
        address custody = IMerkleAdapter(deployed).account();
        assertEq(IMerkleAccount(custody).version(), 2);
        assertEq(Ownable(custody).owner(), curator);
        assertEq(IMerkleAccount(custody).adapter(), deployed);
        assertEq(IMerkleAccount(custody).MERKLE_ADAPTER_FACTORY(), adapter.FACTORY());
        assertTrue(IMerkleAccount(custody).hasRole(bytes32(0), address(this)));
        assertFalse(IMerkleAccount(custody).hasRole(bytes32(0), curator));
        assertEq(IERC20(_asset).allowance(custody, deployed), type(uint256).max);
        assertEq(IMerkleAccount(account).version(), 1);
    }

    function test_MigrationRequiresAccountOwnerAndPreservesStrategy() public {
        address capability = address(new RecipeCapability());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IRecipeCapability.execute.selector;
        CapabilitiesRegistry(IMerkleAccount(account).CAPABILITIES_REGISTRY())
            .whitelistCapability(account, capability, selectors);
        IMerkleAccount(account).addCapability(capability, keccak256(abi.encode(selectors)));
        bytes32 domain = keccak256("test domain");
        bytes memory fields = abi.encode(keccak256("Test(uint256 amount)"), uint256(42));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(fields));
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (domain, fields, flatPlan(fields))));
        IMerkleAccount.Action[] memory actions =
            _publishCall(address(adapter), abi.encodeCall(IMerkleAdapter.pull, (10)));
        bytes32 curRoot = IMerkleAccount(account).root();
        deal(_asset, account, 10);
        address factory = adapter.ACCOUNT_FACTORY();
        IMigratablesFactory(factory)
            .whitelist(
                address(
                    new MerkleAccount(
                        factory, adapter.FACTORY(), address(roots), IMerkleAccount(account).CAPABILITIES_REGISTRY()
                    )
                )
            );
        vm.expectRevert(IMigratablesFactory.NotOwner.selector);
        vm.prank(makeAddr("not owner"));
        IMigratablesFactory(factory).migrate(account, 2, "");
        vm.expectRevert(IMigratableEntity.NotFactory.selector);
        IMerkleAccount(account).migrate(2, "");
        IMigratablesFactory(factory).migrate(account, 2, "");
        assertEq(IMerkleAccount(account).version(), 2);
        assertEq(IMerkleAccount(account).adapter(), address(adapter));
        assertEq(IMerkleAccount(account).MERKLE_ADAPTER_FACTORY(), adapter.FACTORY());
        assertEq(Ownable(account).owner(), address(this));
        assertEq(IMerkleAccount(account).root(), curRoot);
        assertTrue(IMerkleAccount(account).hasRole(curRoot, address(this)));
        assertEq(IMerkleAccount(account).getRoleMemberCount(curRoot), 1);
        assertTrue(_installed(account, capability));
        assertEq(IMerkleAccount(account).capabilityBySelector(selectors[0]), capability);
        assertEq(IMerkleAccount(account).capabilitySelectors(capability, 0), selectors[0]);
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
        assertEq(IERC20(_asset).allowance(account, address(adapter)), type(uint256).max);
        IMerkleAccount(account).manage(actions);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 10);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.pull, (0)));
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 10);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(adapter.stagedLiquidity(), 10);
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(
            OP_CALL, abi.encode(_asset, abi.encodeCall(IERC20.approve, (address(0xBEEF), 42)), new uint256[](0))
        );
        _manage(account, abi.encodeCall(IRecipeCapability.execute, (new bytes[](0), steps, new uint256[](0))));
        assertEq(IERC20(_asset).allowance(account, address(0xBEEF)), 42);
        IMerkleAccount(account).revokeRole(IMerkleAccount(account).root(), address(this));
        assertFalse(IMerkleAccount(account).hasRole(IMerkleAccount(account).root(), address(this)));
    }

    function test_MigrationAuthorityFollowsAccountOwnership() public {
        address factory = adapter.ACCOUNT_FACTORY();
        IMigratablesFactory(factory)
            .whitelist(
                address(
                    new MerkleAccount(
                        factory, adapter.FACTORY(), address(roots), IMerkleAccount(account).CAPABILITIES_REGISTRY()
                    )
                )
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

    function test_OracleWorkflowAndGuardRolesStayLocalAfterAccountOwnershipTransfer() public {
        _setUpWorkflowRegistry();
        address factory = address(new MigratablesFactory(address(this)));
        IMigratablesFactory(factory)
            .whitelist(address(new CREOracle(factory, address(workflowRegistry), makeAddr("forwarder"))));
        address oracle = IMigratablesFactory(factory)
            .create(1, address(this), abi.encode(address(adapter), abi.encode(defaultOracleInitParams(address(this)))));
        address curator = makeAddr("new account owner");
        MerkleAccount(payable(account)).transferOwnership(curator);
        bytes32 workflow = keccak256("workflow");
        _proposeWorkflow(oracle, workflow);
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        vm.prank(curator);
        _acceptWorkflow(oracle, workflow);
        _acceptWorkflow(oracle, workflow);
        assertEq(workflowRegistry.workflowId(oracle), workflow);
        assertEq(adapter.owner(), address(this));
        IMerkleAccount(account).grantRole(keccak256("ORACLE_GUARD_ROLE"), curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, curator, keccak256("ORACLE_GUARD_ROLE")
            )
        );
        vm.prank(curator);
        ICREOracle(oracle).acceptReport("");
        assertTrue(ICREOracle(oracle).hasRole(bytes32(0), address(this)));
        assertFalse(ICREOracle(oracle).hasRole(bytes32(0), curator));
        ICREOracle(oracle).grantRole(keccak256("ORACLE_GUARD_ROLE"), curator);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        vm.prank(curator);
        ICREOracle(oracle).acceptReport("");
        assertTrue(ICREOracle(oracle).hasRole(keccak256("ORACLE_GUARD_ROLE"), curator));
    }

    function testFuzz_PullStagesUnrequestedCash(uint96 balance, uint96 amount) public {
        balance = uint96(bound(balance, 1, 1e24));
        amount = uint96(bound(amount, 0, balance));
        deal(_asset, account, balance);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.pull, (amount)));
        assertEq(IERC20(_asset).balanceOf(account), balance - amount);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), amount);
        assertEq(adapter.stagedLiquidity(), amount);
        assertEq(IERC20(_asset).allowance(account, address(adapter)), type(uint256).max);
    }

    function test_PullRejectsExternalCaller() public {
        deal(_asset, address(adapter), 10);
        vm.expectRevert(IMerkleAdapter.InvalidCaller.selector);
        adapter.pull(10);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 10);
    }

    /// forge-config: default.isolate = true
    function test_PullGas() public {
        deal(_asset, account, 10);
        vm.prank(account);
        adapter.pull(10);
        vm.snapshotGasLastCall("pull");
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 10);
        assertEq(IERC20(_asset).balanceOf(account), 0);
    }

    /// @dev The account no longer exposes membership or a selector count; derive both from enumeration.
    function _installed(address target, address capability) internal view returns (bool) {
        address[] memory list = IMerkleAccount(target).getCapabilities();
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == capability) return true;
        }
        return false;
    }

    function _selectorCount(address target, address capability) internal view returns (uint256 count) {
        while (true) {
            try IMerkleAccount(target).capabilitySelectors(capability, count) returns (bytes4) {
                ++count;
            } catch {
                return count;
            }
        }
    }
}
