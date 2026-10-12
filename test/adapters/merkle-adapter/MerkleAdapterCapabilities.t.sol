// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IMigratableEntityProxy} from "@symbioticfi/core/src/interfaces/common/IMigratableEntityProxy.sol";
import {MigratableEntityProxy} from "@symbioticfi/core/src/contracts/common/MigratableEntityProxy.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {
    MerkleAdapterDelegatorMock,
    MerkleAdapterOracleMock,
    MerkleAdapterVaultMock,
    MerkleAdapterVaultRegistry
} from "test/adapters/MerkleAdapter.t.sol";
import {
    MerkleAdapterRawFallbackCapabilityMock,
    MerkleAdapterStaticCallerMock,
    MerkleAdapterStaticCallbackCapabilityMock,
    MerkleAdapterStateCapabilityMock
} from "test/mocks/MerkleAdapterCapabilityMocks.sol";
import {Token} from "test/mocks/Token.sol";
import {createMerkleAccountFactory} from "test/helpers/MerkleAccountFactory.sol";
import {flatPlan} from "test/helpers/HashPlan.sol";

contract MerkleAdapterCapabilitiesTest is Test {
    MerkleAdapterVaultRegistry internal vaultFactory;
    AdapterFactory internal adapterFactory;
    MigratablesFactory internal oracleFactory;
    RootRegistry internal rootRegistry;
    CapabilitiesRegistry internal capabilityRegistry;
    mapping(address => bytes4[]) internal manifests;
    MerkleAdapterVaultMock internal vault;
    MerkleAdapterDelegatorMock internal delegator;
    Token internal asset;
    MerkleAdapter internal adapter;
    address internal account;
    MerkleAdapterStateCapabilityMock internal stateCapability;
    MerkleAdapterStaticCallbackCapabilityMock internal signatureCapability;

    address internal adapterOwner = makeAddr("adapterOwner");
    address internal protocolOwner = makeAddr("protocolOwner");
    address internal roleAdmin = makeAddr("roleAdmin");
    address internal caller = makeAddr("caller");

    /// @dev Creates the same proxy and oracle path used by the adapter lifecycle suite.
    function setUp() public {
        vaultFactory = new MerkleAdapterVaultRegistry();
        adapterFactory = new AdapterFactory(address(this));
        oracleFactory = new MigratablesFactory(address(this));
        rootRegistry = new RootRegistry(protocolOwner);
        capabilityRegistry = new CapabilitiesRegistry(protocolOwner);
        asset = new Token("Asset");
        vault = new MerkleAdapterVaultMock(address(asset));
        delegator = new MerkleAdapterDelegatorMock(address(vault));
        vault.setDelegator(address(delegator));
        vaultFactory.add(address(vault));

        oracleFactory.whitelist(address(new MerkleAdapterOracleMock(address(oracleFactory))));
        adapterFactory.whitelist(
            address(
                new MerkleAdapter(
                    address(vaultFactory),
                    address(adapterFactory),
                    address(oracleFactory),
                    createMerkleAccountFactory(
                        address(this), address(adapterFactory), address(rootRegistry), address(capabilityRegistry)
                    )
                )
            )
        );
        adapter = _createAdapter();
        account = adapter.account();
        stateCapability = new MerkleAdapterStateCapabilityMock();
        signatureCapability = new MerkleAdapterStaticCallbackCapabilityMock();
        _initCapability(address(stateCapability), _stateSelectors());
        _initCapability(
            address(signatureCapability),
            _singleSelector(MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector)
        );
    }

    function test_ConstructorStoresZeroAndNonContractRegistry() public {
        address[2] memory invalidRegistries = [address(0), caller];
        for (uint256 i; i < invalidRegistries.length; ++i) {
            address uncheckedAccount = address(
                new MerkleAccount(
                    adapter.ACCOUNT_FACTORY(), address(adapterFactory), address(rootRegistry), invalidRegistries[i]
                )
            );
            assertEq(IMerkleAccount(uncheckedAccount).CAPABILITIES_REGISTRY(), invalidRegistries[i]);
        }
    }

    /// @dev Registry approval makes a module eligible; the adapter owner's installation enables its selectors.
    /// forge-config: default.isolate = true
    function test_AddCapabilityRequiresRegistryApprovalAndOwnerInstallation() public {
        bytes4 selector = MerkleAdapterStateCapabilityMock.capabilityState.selector;
        assertEq(MerkleAccount(payable(account)).CAPABILITIES_REGISTRY(), address(capabilityRegistry));
        assertFalse(_installed(account, address(stateCapability)));
        _expectUnknown(account, abi.encodeWithSelector(selector), selector);

        _setWhitelisted(adapter, address(stateCapability), true);
        assertEq(MerkleAccount(payable(account)).capabilityBySelector(selector), address(0));
        _expectUnknown(account, abi.encodeWithSelector(selector), selector);

        vm.expectEmit(true, false, false, false, account);
        emit IMerkleAccount.AddCapability(address(stateCapability));
        _addCapability(adapter, address(stateCapability));
        vm.snapshotGasLastCall("MerkleAccount", "addCapabilityFourSelectors");

        assertTrue(_installed(account, address(stateCapability)));
        address[] memory capabilities = MerkleAccount(payable(account)).getCapabilities();
        vm.snapshotGasLastCall("MerkleAccount", "getCapabilitiesConfigured");
        assertEq(capabilities.length, 1);
        assertEq(capabilities[0], address(stateCapability));
        bytes4[] memory selectors = _stateSelectors();
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(MerkleAccount(payable(account)).capabilityBySelector(selectors[i]), address(stateCapability));
        }
        _assertState(account, 0, address(0), 0, address(0));
    }

    /// @dev Protocol approval is scoped to the exact proxy and cannot be reused by another adapter.
    function test_AddCapabilityRejectsApprovalForAnotherAdapter() public {
        MerkleAdapter otherAdapter = _createAdapter();
        address otherAccount = otherAdapter.account();
        _setWhitelisted(otherAdapter, address(stateCapability), true);

        vm.expectRevert(IMerkleAccount.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account))
            .addCapability(address(stateCapability), keccak256(abi.encode(manifests[address(stateCapability)])));

        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
        _addCapability(otherAdapter, address(stateCapability));
        assertTrue(_installed(otherAdapter.account(), address(stateCapability)));
        assertFalse(_installed(account, address(stateCapability)));
    }

    /// @dev Unapproved implementations cannot gain access to adapter storage.
    /// forge-config: default.isolate = true
    function test_AddCapabilityRejectsUnapprovedModule() public {
        vm.expectRevert(IMerkleAccount.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        vm.startSnapshotGas("MerkleAccount", "addCapabilityUnapprovedRegion");
        MerkleAccount(payable(account))
            .addCapability(address(stateCapability), keccak256(abi.encode(manifests[address(stateCapability)])));
        vm.stopSnapshotGas();

        address[] memory capabilities = MerkleAccount(payable(account)).getCapabilities();
        vm.snapshotGasLastCall("MerkleAccount", "getCapabilitiesEmpty");
        assertEq(capabilities.length, 0);
        assertEq(
            MerkleAccount(payable(account))
                .capabilityBySelector(MerkleAdapterStateCapabilityMock.setCapabilityValue.selector),
            address(0)
        );
    }

    /// @dev Protocol owners, role administrators, and arbitrary callers cannot install capabilities.
    function test_AddCapabilityRejectsEveryNonOwner() public {
        _setWhitelisted(adapter, address(stateCapability), true);
        address[3] memory nonOwners = [protocolOwner, roleAdmin, caller];
        for (uint256 i; i < nonOwners.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwners[i])
            );
            vm.prank(nonOwners[i]);
            MerkleAccount(payable(account))
                .addCapability(address(stateCapability), keccak256(abi.encode(manifests[address(stateCapability)])));
        }
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
    }

    /// @dev Installing an existing module cannot duplicate its enumeration entry.
    function test_AddCapabilityRejectsDuplicate() public {
        _installStateCapability(adapter);

        vm.expectRevert(IMerkleAccount.CapabilityAlreadyAdded.selector);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account))
            .addCapability(address(stateCapability), keccak256(abi.encode(manifests[address(stateCapability)])));

        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 1);
        assertEq(
            MerkleAccount(payable(account))
                .capabilityBySelector(MerkleAdapterStateCapabilityMock.capabilityState.selector),
            address(stateCapability)
        );
    }

    /// @dev A later collision rolls back the earlier selector and the new module's enumeration entry.
    function test_AddCapabilityRollsBackEverySelectorOnCollision() public {
        _installStateCapability(adapter);
        bytes4 freshSelector = 0x12345678;
        bytes4 occupiedSelector = MerkleAdapterStateCapabilityMock.capabilityState.selector;
        address colliding = address(new MerkleAdapterStateCapabilityMock());
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = freshSelector;
        selectors[1] = occupiedSelector;
        _initCapability(colliding, selectors);
        _setWhitelisted(adapter, colliding, true);

        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.SelectorAlreadyUsed.selector));
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).addCapability(colliding, keccak256(abi.encode(manifests[colliding])));

        assertEq(MerkleAccount(payable(account)).capabilityBySelector(freshSelector), address(0));
        assertEq(MerkleAccount(payable(account)).capabilityBySelector(occupiedSelector), address(stateCapability));
        assertFalse(_installed(account, colliding));
        assertEq(_selectorCount(account, colliding), 0);
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 1);
        _assertState(account, 0, address(0), 0, address(0));
    }

    function test_DuplicateSelectorRollsBackInstalledList() public {
        bytes4 selector = MerkleAdapterStateCapabilityMock.capabilityState.selector;
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = selector;
        selectors[1] = selector;
        vm.prank(protocolOwner);
        capabilityRegistry.whitelistCapability(account, address(stateCapability), selectors);
        vm.expectRevert(IMerkleAccount.SelectorAlreadyUsed.selector);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).addCapability(address(stateCapability), keccak256(abi.encode(selectors)));
        assertFalse(_installed(account, address(stateCapability)));
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
        assertEq(_selectorCount(account, address(stateCapability)), 0);
        assertEq(MerkleAccount(payable(account)).capabilityBySelector(selector), address(0));
    }

    /// @dev Native selectors can be registered and removed like any other capability selectors.
    function test_AddCapabilityAcceptsEveryNativeSelectorFromCompiledAbi() public {
        string memory artifact = vm.readFile("out/MerkleAccount.sol/MerkleAccount.json");
        string[] memory signatures = vm.parseJsonKeys(artifact, ".methodIdentifiers");
        assertGt(signatures.length, 0);
        bytes4[] memory selectors = new bytes4[](signatures.length);
        for (uint256 i; i < signatures.length; ++i) {
            selectors[i] = bytes4(keccak256(bytes(signatures[i])));
        }
        address capability = address(new MerkleAdapterRawFallbackCapabilityMock());
        _initCapability(capability, selectors);
        _setWhitelisted(adapter, capability, true);
        _addCapability(adapter, capability);

        assertTrue(_installed(account, capability));
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 1);
        assertEq(MerkleAccount(payable(account)).getCapabilities()[0], capability);
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(MerkleAccount(payable(account)).capabilityBySelector(selectors[i]), capability);
        }
        assertEq(adapter.owner(), adapterOwner);
        assertEq(adapter.vault(), address(vault));

        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(capability);

        assertFalse(_installed(account, capability));
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(MerkleAccount(payable(account)).capabilityBySelector(selectors[i]), address(0));
        }
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
        assertEq(adapter.owner(), adapterOwner);
        assertEq(adapter.vault(), address(vault));
    }

    /// @dev Registered native reads, writes, and reverts retain their ordinary dispatch and authorization.
    function test_AddCapabilityDoesNotShadowNativeFunctions() public {
        address capability = address(new MerkleAdapterRawFallbackCapabilityMock());
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = IMerkleAccount.adapter.selector;
        selectors[1] = IMerkleAccount.sign.selector;
        selectors[2] = IMerkleAccount.manage.selector;
        selectors[3] = 0x12345678;
        _initCapability(capability, selectors);
        _setWhitelisted(adapter, capability, true);
        _addCapability(adapter, capability);

        bytes memory data = abi.encodeWithSelector(selectors[3], uint256(17));
        (bool success, bytes memory result) = account.call(data);
        assertTrue(success);
        assertEq(result, data);
        assertEq(IMerkleAccount(account).adapter(), address(adapter));
        vm.expectRevert(IMerkleAccount.InvalidCaller.selector);
        vm.prank(caller);
        IMerkleAccount(account)
            .sign(bytes32(0), abi.encode(bytes32(uint256(1))), flatPlan(abi.encode(bytes32(uint256(1)))));
        vm.prank(caller);
        assertEq(IMerkleAccount(account).manage(new IMerkleAccount.Action[](0)).length, 0);
        assertEq(MerkleAccount(payable(account)).owner(), adapterOwner);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        MerkleAccount(payable(account)).transferOwnership(caller);
        assertEq(MerkleAccount(payable(account)).owner(), adapterOwner);

        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).transferOwnership(caller);
        assertEq(MerkleAccount(payable(account)).owner(), caller);
        assertEq(MerkleAccount(payable(account)).capabilityBySelector(selectors[1]), capability);

        vm.prank(caller);
        MerkleAccount(payable(account)).removeCapability(capability);
        assertFalse(_installed(account, capability));
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(MerkleAccount(payable(account)).capabilityBySelector(selectors[i]), address(0));
        }
    }

    /// @dev A registered upgrade selector cannot bypass proxy authorization or intercept an authorized upgrade.
    function test_AddCapabilityAcceptsProxyUpgradeSelectorWithoutShadowingProxy() public {
        _installStateCapability(adapter);
        address capability = address(new MerkleAdapterRawFallbackCapabilityMock());
        bytes4 selector = IMigratableEntityProxy.upgradeToAndCall.selector;
        _initCapability(capability, _singleSelector(selector));
        _setWhitelisted(adapter, capability, true);
        _addCapability(adapter, capability);
        assertTrue(_installed(account, capability));
        assertEq(MerkleAccount(payable(account)).capabilityBySelector(selector), capability);

        address factory = adapter.ACCOUNT_FACTORY();
        address implementation = MigratablesFactory(factory).implementation(1);
        bytes memory data = abi.encodeCall(MerkleAdapterStateCapabilityMock.setCapabilityValue, (31));
        vm.expectRevert(MigratableEntityProxy.ProxyDeniedAdminAccess.selector);
        vm.prank(adapterOwner);
        IMigratableEntityProxy(account).upgradeToAndCall(implementation, data);
        _assertState(account, 0, address(0), 0, address(0));

        vm.prank(factory);
        IMigratableEntityProxy(account).upgradeToAndCall(implementation, "");
        _assertState(account, 0, address(0), 0, address(0));
        assertEq(MerkleAccount(payable(account)).capabilityBySelector(selector), capability);

        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(capability);
        assertFalse(_installed(account, capability));
        assertEq(MerkleAccount(payable(account)).capabilityBySelector(selector), address(0));
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 1);
        assertTrue(_installed(account, address(stateCapability)));
    }

    /// @dev Removal clears every selector while retaining unrelated modules.
    /// forge-config: default.isolate = true
    function test_RemoveCapabilityClearsSelectorsAndPreservesOtherCapabilities() public {
        _installStateCapability(adapter);
        _setWhitelisted(adapter, address(signatureCapability), true);
        _addCapability(adapter, address(signatureCapability));

        vm.expectEmit(true, false, false, false, account);
        emit IMerkleAccount.RemoveCapability(address(stateCapability));
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(address(stateCapability));
        vm.snapshotGasLastCall("MerkleAccount", "removeCapabilityNonLast");

        assertFalse(_installed(account, address(stateCapability)));
        bytes4[] memory selectors = _stateSelectors();
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(MerkleAccount(payable(account)).capabilityBySelector(selectors[i]), address(0));
            _expectUnknown(account, abi.encodeWithSelector(selectors[i]), selectors[i]);
        }
        address[] memory capabilities = MerkleAccount(payable(account)).getCapabilities();
        assertEq(capabilities.length, 1);
        assertEq(capabilities[0], address(signatureCapability));
        assertTrue(_installed(account, address(signatureCapability)));
        assertEq(
            MerkleAccount(payable(account))
                .capabilityBySelector(MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector),
            address(signatureCapability)
        );
    }

    /// @dev Only the adapter owner can remove an installed module.
    function test_RemoveCapabilityRejectsEveryNonOwner() public {
        _installStateCapability(adapter);
        address[3] memory nonOwners = [protocolOwner, roleAdmin, caller];
        for (uint256 i; i < nonOwners.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwners[i])
            );
            vm.prank(nonOwners[i]);
            MerkleAccount(payable(account)).removeCapability(address(stateCapability));
        }
        assertTrue(_installed(account, address(stateCapability)));
        _assertState(account, 0, address(0), 0, address(0));
    }

    /// @dev Missing and already removed modules cannot corrupt enumeration.
    /// forge-config: default.isolate = true
    function test_RemoveCapabilityRejectsMissingModule() public {
        vm.expectRevert(IMerkleAccount.CapabilityNotAdded.selector);
        vm.prank(adapterOwner);
        vm.startSnapshotGas("MerkleAccount", "removeCapabilityMissingRegion");
        MerkleAccount(payable(account)).removeCapability(address(stateCapability));
        vm.stopSnapshotGas();

        _installStateCapability(adapter);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(address(stateCapability));

        vm.expectRevert(IMerkleAccount.CapabilityNotAdded.selector);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(address(stateCapability));
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
    }

    /// @dev Revoked protocol approval cannot prevent the adapter owner from uninstalling the module.
    /// forge-config: default.isolate = true
    function test_RemoveCapabilityRemainsAvailableAfterApprovalRevocation() public {
        _installStateCapability(adapter);
        _setWhitelisted(adapter, address(stateCapability), false);

        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(address(stateCapability));
        vm.snapshotGasLastCall("MerkleAccount", "removeCapabilityLast");

        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
        assertFalse(_installed(account, address(stateCapability)));
        bytes4 selector = MerkleAdapterStateCapabilityMock.capabilityState.selector;
        assertEq(MerkleAccount(payable(account)).capabilityBySelector(selector), address(0));
        _expectUnknown(account, abi.encodeWithSelector(selector), selector);
    }

    /// @dev Freed selectors can be installed from another implementation without erasing namespaced adapter state.
    function test_RemoveCapabilityAllowsSelectorReuseByReplacement() public {
        _installStateCapability(adapter);
        vm.prank(caller);
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(17);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(address(stateCapability));

        address replacement = address(new MerkleAdapterStateCapabilityMock());
        _initCapability(replacement, _stateSelectors());
        _setWhitelisted(adapter, replacement, true);
        _addCapability(adapter, replacement);

        assertEq(
            MerkleAccount(payable(account))
                .capabilityBySelector(MerkleAdapterStateCapabilityMock.capabilityState.selector),
            replacement
        );
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 1);
        assertEq(MerkleAccount(payable(account)).getCapabilities()[0], replacement);
        _assertState(account, 17, caller, 0, account);
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(23);
        _assertState(account, 23, address(this), 0, account);
    }

    /// @dev The module receives the external sender and value and executes in the adapter's balance/storage context.
    /// forge-config: default.isolate = true
    function test_FallbackPreservesSenderValueAndAdapterContext() public {
        _installStateCapability(adapter);
        vm.deal(caller, 3 ether);

        vm.prank(caller);
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue{value: 2 ether}(42);
        vm.snapshotGasLastCall("MerkleAccount", "fallbackDelegatecall");

        _assertState(account, 42, caller, 2 ether, account);
        _assertState(address(stateCapability), 0, address(0), 0, address(0));
        assertEq(account.balance, 2 ether);
        assertEq(address(stateCapability).balance, 0);
        assertEq(caller.balance, 1 ether);
    }

    /// @dev A shared implementation keeps writes isolated between adapters and from native adapter state.
    function test_FallbackKeepsNamespacedStateSeparateForTwoAdapters() public {
        MerkleAdapter otherAdapter = _createAdapter();
        address otherAccount = otherAdapter.account();
        _installStateCapability(adapter);
        _installStateCapability(otherAdapter);
        address firstOracle = adapter.oracle();
        address secondOracle = otherAdapter.oracle();
        asset.transfer(address(adapter), 19);

        vm.prank(caller);
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(111);
        vm.prank(adapterOwner);
        MerkleAdapterStateCapabilityMock(otherAccount).setCapabilityValue(222);

        _assertState(account, 111, caller, 0, account);
        _assertState(otherAccount, 222, adapterOwner, 0, otherAccount);
        _assertState(address(stateCapability), 0, address(0), 0, address(0));
        assertEq(adapter.vault(), address(vault));
        assertEq(otherAdapter.vault(), address(vault));
        assertEq(adapter.owner(), adapterOwner);
        assertEq(otherAdapter.owner(), adapterOwner);
        assertEq(adapter.oracle(), firstOracle);
        assertEq(otherAdapter.oracle(), secondOracle);
        assertEq(asset.balanceOf(address(adapter)), 19);
        assertEq(adapter.freeAssets(), 0);
        assertEq(otherAdapter.freeAssets(), 0);
        assertTrue(
            MerkleAccount(payable(account)).hasRole(MerkleAccount(payable(account)).DEFAULT_ADMIN_ROLE(), roleAdmin)
        );
        assertTrue(
            MerkleAccount(payable(otherAdapter.account()))
                .hasRole(MerkleAccount(payable(otherAdapter.account())).DEFAULT_ADMIN_ROLE(), roleAdmin)
        );
    }

    /// @dev A real view callback reaches the adapter address under STATICCALL, including its original protocol caller.
    function test_FallbackSupportsStaticCallbackAtAdapterAddress() public {
        _setWhitelisted(adapter, address(signatureCapability), true);
        _addCapability(adapter, address(signatureCapability));
        MerkleAdapterStaticCallerMock callbackCaller = new MerkleAdapterStaticCallerMock();
        bytes memory signature = abi.encode(account, address(callbackCaller));

        assertEq(
            callbackCaller.checkCallback(account, keccak256("merkle adapter callback"), signature),
            MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector
        );
        assertEq(callbackCaller.checkCallback(account, bytes32(0), signature), bytes4(0xffffffff));
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 1);
    }

    /// @dev Revoking approval leaves an installed static callback active until its owner removes the capability.
    function test_FallbackKeepsRevokedCallbackActiveUntilOwnerRemoval() public {
        _setWhitelisted(adapter, address(signatureCapability), true);
        _addCapability(adapter, address(signatureCapability));
        MerkleAdapterStaticCallerMock callbackCaller = new MerkleAdapterStaticCallerMock();
        bytes memory signature = abi.encode(account, address(callbackCaller));
        bytes32 digest = keccak256("merkle adapter callback");
        assertEq(
            callbackCaller.checkCallback(account, digest, signature),
            MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector
        );

        _setWhitelisted(adapter, address(signatureCapability), false);

        assertEq(
            callbackCaller.checkCallback(account, digest, signature),
            MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector
        );
        assertTrue(_installed(account, address(signatureCapability)));
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 1);
        assertEq(
            MerkleAccount(payable(account))
                .capabilityBySelector(MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector),
            address(signatureCapability)
        );

        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(address(signatureCapability));

        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.UnknownSelector.selector));
        callbackCaller.checkCallback(account, digest, signature);
        vm.expectRevert(IMerkleAccount.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account))
            .addCapability(address(signatureCapability), keccak256(abi.encode(manifests[address(signatureCapability)])));
        assertFalse(_installed(account, address(signatureCapability)));
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
        assertEq(
            MerkleAccount(payable(account))
                .capabilityBySelector(MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector),
            address(0)
        );

        _setWhitelisted(adapter, address(signatureCapability), true);
        _addCapability(adapter, address(signatureCapability));
        assertEq(
            callbackCaller.checkCallback(account, digest, signature),
            MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector
        );
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 1);
    }

    /// @dev Installed writes remain active after revocation, while approval for another adapter cannot permit reinstalling.
    function test_FallbackKeepsRevokedWritesActiveAndScopesReinstallationApproval() public {
        MerkleAdapter otherAdapter = _createAdapter();
        address otherAccount = otherAdapter.account();
        _installStateCapability(adapter);
        _installStateCapability(otherAdapter);
        _setWhitelisted(adapter, address(stateCapability), false);

        vm.prank(caller);
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(1);
        MerkleAdapterStateCapabilityMock(otherAccount).setCapabilityValue(2);

        _assertState(account, 1, caller, 0, account);
        _assertState(otherAccount, 2, address(this), 0, otherAccount);

        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(address(stateCapability));
        vm.expectRevert(IMerkleAccount.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account))
            .addCapability(address(stateCapability), keccak256(abi.encode(manifests[address(stateCapability)])));
        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.UnknownSelector.selector));
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(3);
        MerkleAdapterStateCapabilityMock(otherAccount).setCapabilityValue(4);
        _assertState(otherAccount, 4, address(this), 0, otherAccount);

        _setWhitelisted(adapter, address(stateCapability), true);
        _addCapability(adapter, address(stateCapability));
        _assertState(account, 1, caller, 0, account);
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(5);
        _assertState(account, 5, address(this), 0, account);
    }

    /// @dev Owner installation and module execution in one multicall preserve the external owner and existing storage.
    function test_MulticallReplacesCapabilityAtomicallyWithoutInitializingState() public {
        _installStateCapability(adapter);
        vm.prank(caller);
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(17);
        address replacement = address(new MerkleAdapterStateCapabilityMock());
        _initCapability(replacement, _stateSelectors());
        _setWhitelisted(adapter, replacement, true);

        bytes[] memory calls = _replacementCalls(replacement);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).multicall(calls);

        assertFalse(_installed(account, address(stateCapability)));
        assertTrue(_installed(account, replacement));
        _assertState(account, 17, caller, 0, account);

        vm.prank(adapterOwner);
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(23);
        _assertState(account, 23, adapterOwner, 0, account);
    }

    /// @dev An unauthorized multicall cannot acquire owner permissions through self-delegatecall.
    function test_MulticallPreservesOwnerAuthorization() public {
        _setWhitelisted(adapter, address(stateCapability), true);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            IMerkleAccount.addCapability,
            (address(stateCapability), keccak256(abi.encode(manifests[address(stateCapability)])))
        );

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        MerkleAccount(payable(account)).multicall(calls);

        assertFalse(_installed(account, address(stateCapability)));
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
    }

    /// @dev A replacement without protocol approval must restore the removed module when the batch reverts.
    function test_MulticallRollsBackRemovalWhenReplacementIsUnapproved() public {
        _assertReplacementRollback(false);
    }

    /// @dev A replacement colliding with a retained callback must restore the removed module and all its selectors.
    function test_MulticallRollsBackRemovalWhenReplacementCollides() public {
        _assertReplacementRollback(true);
    }

    /// @dev Stateful randomized approvals, additions and removals keep routing and enumeration consistent.
    function testFuzz_SelectorRoutingMatchesInstalledCapabilitiesAcrossOperations(uint256 seed) public {
        address replacement = address(new MerkleAdapterStateCapabilityMock());
        _initCapability(replacement, _stateSelectors());
        address[3] memory capabilities = [address(stateCapability), replacement, address(signatureCapability)];
        bool[3] memory approved;
        bool[3] memory installed;

        for (uint256 step; step < 32; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 selected = seed % 3;
            uint256 action = (seed / 3) % 4;
            if (action < 2) {
                approved[selected] = action == 0;
                _setWhitelisted(adapter, capabilities[selected], approved[selected]);
            } else {
                bool expected = action == 2
                    ? approved[selected] && !installed[selected] && (selected == 2 || !installed[1 - selected])
                    : installed[selected];
                bytes memory data = action == 2
                    ? abi.encodeCall(
                        IMerkleAccount.addCapability,
                        (capabilities[selected], keccak256(abi.encode(manifests[capabilities[selected]])))
                    )
                    : abi.encodeCall(IMerkleAccount.removeCapability, (capabilities[selected]));
                vm.prank(adapterOwner);
                (bool success,) = account.call(data);
                assertEq(success, expected);
                if (success) {
                    installed[selected] = action == 2;
                }
            }
            _assertRoutingMatchesModel(capabilities, installed);
        }
    }

    /// @dev Return data is copied byte-for-byte, including lengths that do not align to ABI words.
    function testFuzz_FallbackForwardsRawReturnData(bytes memory expected) public {
        vm.assume(expected.length <= 4096);
        _installStateCapability(adapter);

        (bool success, bytes memory actual) =
            account.call(abi.encodeCall(MerkleAdapterStateCapabilityMock.returnRaw, (expected)));

        assertTrue(success);
        assertEq(actual, expected);
    }

    /// @dev Both storage writes and received ETH roll back, while revert bytes survive both delegatecall layers.
    function testFuzz_FallbackForwardsRawRevertDataAndRollsBack(bytes memory expected) public {
        vm.assume(expected.length <= 4096);
        _installStateCapability(adapter);
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(7);
        vm.deal(caller, 1 ether);

        vm.prank(caller);
        (bool success, bytes memory actual) = account.call{value: 1 ether}(
            abi.encodeCall(MerkleAdapterStateCapabilityMock.writeThenRevert, (99, expected))
        );

        assertFalse(success);
        assertEq(actual, expected);
        _assertState(account, 7, address(this), 0, account);
        assertEq(account.balance, 0);
        assertEq(caller.balance, 1 ether);
    }

    /// @dev An unknown full selector cannot dispatch to an arbitrary implementation.
    function test_FallbackRejectsUnknownSelector() public {
        _installStateCapability(adapter);
        _expectUnknown(account, hex"1234567801020304", 0x12345678);
    }

    /// @dev Nonempty payloads shorter than four bytes cannot masquerade as padded selectors.
    function test_FallbackRejectsShortCalldata() public {
        address rawCapability = address(new MerkleAdapterRawFallbackCapabilityMock());
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = 0x12000000;
        selectors[1] = 0x12340000;
        selectors[2] = 0x12345600;
        _initCapability(rawCapability, selectors);
        _setWhitelisted(adapter, rawCapability, true);
        _addCapability(adapter, rawCapability);
        for (uint256 i; i < selectors.length; ++i) {
            bytes memory data = abi.encodePacked(selectors[i]);
            (bool success, bytes memory result) = account.call(data);
            assertTrue(success);
            assertEq(result, data);
        }
        _expectUnknown(account, hex"12", 0x12000000);
        _expectUnknown(account, hex"1234", 0x12340000);
        _expectUnknown(account, hex"123456", 0x12345600);
    }

    /// @dev Existing plain ETH funding remains available independently of capability routing.
    /// forge-config: default.isolate = true
    function test_ReceiveKeepsPlainEthFundingAvailable() public {
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        (bool success, bytes memory result) = account.call{value: 1 ether}("");
        vm.snapshotGasLastCall("MerkleAccount", "receive");

        assertTrue(success);
        assertEq(result.length, 0);
        assertEq(account.balance, 1 ether);
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
    }

    function test_RegistryOverwriteDoesNotChangeInstalledRoutesOrRemoval() public {
        _installStateCapability(adapter);
        _setWhitelisted(adapter, address(signatureCapability), true);
        _addCapability(adapter, address(signatureCapability));
        vm.prank(protocolOwner);
        capabilityRegistry.whitelistCapability(
            account,
            address(stateCapability),
            _singleSelector(MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector)
        );
        _assertCapabilitySelectors(address(stateCapability), _stateSelectors());
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(21);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(address(stateCapability));
        _assertCapabilitySelectors(address(stateCapability), new bytes4[](0));
        assertEq(
            MerkleAccount(payable(account))
                .capabilityBySelector(MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector),
            address(signatureCapability)
        );
        _expectUnknown(
            account,
            abi.encodeWithSelector(MerkleAdapterStateCapabilityMock.capabilityState.selector),
            MerkleAdapterStateCapabilityMock.capabilityState.selector
        );
    }

    function test_UnwhitelistingPreservesRoutesButBlocksReinstallation() public {
        _installStateCapability(adapter);
        _setWhitelisted(adapter, address(stateCapability), false);
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(21);
        _assertState(account, 21, address(this), 0, account);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(address(stateCapability));
        vm.expectRevert(IMerkleAccount.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account))
            .addCapability(address(stateCapability), keccak256(abi.encode(manifests[address(stateCapability)])));

        _setWhitelisted(adapter, address(stateCapability), true);
        _addCapability(adapter, address(stateCapability));
        _assertState(account, 21, address(this), 0, account);
    }

    function test_InstallationRejectsRegistrySelectorReplacement() public {
        _setWhitelisted(adapter, address(stateCapability), true);
        vm.prank(protocolOwner);
        capabilityRegistry.whitelistCapability(
            account,
            address(stateCapability),
            _singleSelector(MerkleAdapterStateCapabilityMock.capabilityState.selector)
        );

        vm.expectRevert(IMerkleAccount.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account))
            .addCapability(address(stateCapability), keccak256(abi.encode(manifests[address(stateCapability)])));
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
        assertEq(
            MerkleAccount(payable(account))
                .capabilityBySelector(MerkleAdapterStateCapabilityMock.capabilityState.selector),
            address(0)
        );
    }

    function test_ReinstallationUsesCurrentSelectors() public {
        _installStateCapability(adapter);
        bytes4 selector = MerkleAdapterStateCapabilityMock.capabilityState.selector;
        vm.prank(protocolOwner);
        capabilityRegistry.whitelistCapability(account, address(stateCapability), _singleSelector(selector));
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(address(stateCapability));
        manifests[address(stateCapability)] = _singleSelector(selector);
        _addCapability(adapter, address(stateCapability));
        _assertCapabilitySelectors(address(stateCapability), _singleSelector(selector));
        _assertState(account, 0, address(0), 0, address(0));
        bytes4 removedSelector = MerkleAdapterStateCapabilityMock.setCapabilityValue.selector;
        _expectUnknown(account, abi.encodeWithSelector(removedSelector, 42), removedSelector);
    }

    function test_CallbacksAndRemovalRemainAvailableWithoutRegistry(bool reverting) public {
        _installStateCapability(adapter);
        vm.etch(address(capabilityRegistry), reverting ? bytes(hex"60006000fd") : bytes(""));
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(31);
        _assertState(account, 31, address(this), 0, account);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).removeCapability(address(stateCapability));
        assertFalse(_installed(account, address(stateCapability)));
        _assertCapabilitySelectors(address(stateCapability), new bytes4[](0));
        bytes4 selector = MerkleAdapterStateCapabilityMock.capabilityState.selector;
        _expectUnknown(account, abi.encodeWithSelector(selector), selector);
    }

    function test_WhitelistInAnotherRegistryCannotAuthorizeInstallation() public {
        CapabilitiesRegistry otherRegistry = new CapabilitiesRegistry(protocolOwner);
        vm.prank(protocolOwner);
        otherRegistry.whitelistCapability(account, address(stateCapability), _stateSelectors());
        vm.expectRevert(IMerkleAccount.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account))
            .addCapability(address(stateCapability), keccak256(abi.encode(manifests[address(stateCapability)])));
    }

    function _assertCapabilitySelectors(address capability, bytes4[] memory expected) internal {
        assertEq(_selectorCount(account, capability), expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(MerkleAccount(payable(account)).capabilitySelectors(capability, i), expected[i]);
        }
        vm.expectRevert();
        MerkleAccount(payable(account)).capabilitySelectors(capability, expected.length);
    }

    /// @dev Factory creation keeps adapter setup independent of capability installation.
    function _createAdapter() internal returns (MerkleAdapter) {
        IMerkleAdapter.InitParams memory params = merkleAdapterInitParams(roleAdmin);
        return
            MerkleAdapter(
                payable(adapterFactory.create(1, adapterOwner, abi.encode(address(vault), abi.encode(params))))
            );
    }

    /// @dev Keeps a test manifest for subsequent per-adapter whitelist calls.
    function _initCapability(address capability, bytes4[] memory selectors) internal {
        manifests[capability] = selectors;
    }

    function _setWhitelisted(MerkleAdapter target, address capability, bool status) internal {
        bytes4[] memory selectors = status ? manifests[capability] : new bytes4[](0);
        address targetAccount = target.account();
        vm.prank(protocolOwner);
        capabilityRegistry.whitelistCapability(targetAccount, capability, selectors);
    }

    /// @dev Installs a previously approved implementation as the adapter owner.
    function _addCapability(MerkleAdapter target, address capability) internal {
        address targetAccount = target.account();
        vm.prank(adapterOwner);
        IMerkleAccount(targetAccount).addCapability(capability, keccak256(abi.encode(manifests[capability])));
    }

    /// @dev Enables the shared state module for the requested adapter.
    function _installStateCapability(MerkleAdapter target) internal {
        _setWhitelisted(target, address(stateCapability), true);
        _addCapability(target, address(stateCapability));
    }

    /// @dev Lists only the mock's intended public module entry points.
    function _stateSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = MerkleAdapterStateCapabilityMock.setCapabilityValue.selector;
        selectors[1] = MerkleAdapterStateCapabilityMock.capabilityState.selector;
        selectors[2] = MerkleAdapterStateCapabilityMock.returnRaw.selector;
        selectors[3] = MerkleAdapterStateCapabilityMock.writeThenRevert.selector;
    }

    /// @dev Builds a one-selector registration for callback and collision cases.
    function _singleSelector(bytes4 selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    /// @dev Builds the actual remove-then-add batch exposed by the inherited multicall interface.
    function _replacementCalls(address replacement) internal view returns (bytes[] memory calls) {
        calls = new bytes[](2);
        calls[0] = abi.encodeCall(IMerkleAccount.removeCapability, (address(stateCapability)));
        calls[1] =
            abi.encodeCall(IMerkleAccount.addCapability, (replacement, keccak256(abi.encode(manifests[replacement]))));
    }

    /// @dev Exercises replacement failure after removal already ran, then checks the original routing and state.
    function _assertReplacementRollback(bool collision) internal {
        _installStateCapability(adapter);
        _setWhitelisted(adapter, address(signatureCapability), true);
        _addCapability(adapter, address(signatureCapability));
        MerkleAdapterStateCapabilityMock(account).setCapabilityValue(17);
        address replacement = address(new MerkleAdapterStateCapabilityMock());
        bytes4[] memory selectors = _stateSelectors();
        if (collision) {
            selectors[3] = MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector;
        }
        _initCapability(replacement, selectors);
        if (collision) {
            _setWhitelisted(adapter, replacement, true);
        }
        bytes[] memory calls = _replacementCalls(replacement);
        bytes memory errorData = collision
            ? abi.encodeWithSelector(IMerkleAccount.SelectorAlreadyUsed.selector)
            : abi.encodeWithSelector(IMerkleAccount.CapabilityNotWhitelisted.selector);
        vm.expectRevert(errorData);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).multicall(calls);

        assertTrue(_installed(account, address(stateCapability)));
        assertTrue(_installed(account, address(signatureCapability)));
        assertFalse(_installed(account, replacement));
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 2);
        selectors = _stateSelectors();
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(MerkleAccount(payable(account)).capabilityBySelector(selectors[i]), address(stateCapability));
        }
        assertEq(
            MerkleAccount(payable(account))
                .capabilityBySelector(MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector),
            address(signatureCapability)
        );
        _assertState(account, 17, address(this), 0, account);
    }

    /// @dev Compares enumeration and every registered selector against an independent operation model.
    function _assertRoutingMatchesModel(address[3] memory capabilities, bool[3] memory installed) internal view {
        address[] memory actual = MerkleAccount(payable(account)).getCapabilities();
        bool[3] memory seen;
        uint256 expectedCount;
        for (uint256 i; i < capabilities.length; ++i) {
            assertEq(_installed(account, capabilities[i]), installed[i]);
            if (installed[i]) {
                ++expectedCount;
            }
        }
        assertEq(actual.length, expectedCount);
        for (uint256 i; i < actual.length; ++i) {
            bool found;
            for (uint256 j; j < capabilities.length; ++j) {
                if (actual[i] == capabilities[j]) {
                    assertTrue(installed[j]);
                    assertFalse(seen[j]);
                    seen[j] = true;
                    found = true;
                }
            }
            assertTrue(found);
        }
        assertFalse(installed[0] && installed[1]);
        address expectedState = installed[0] ? capabilities[0] : installed[1] ? capabilities[1] : address(0);
        bytes4[] memory selectors = _stateSelectors();
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(MerkleAccount(payable(account)).capabilityBySelector(selectors[i]), expectedState);
        }
        assertEq(
            MerkleAccount(payable(account))
                .capabilityBySelector(MerkleAdapterStaticCallbackCapabilityMock.staticCallback.selector),
            installed[2] ? capabilities[2] : address(0)
        );
    }

    /// @dev Verifies the public error and original selector rather than only observing a failed call.
    function _expectUnknown(address target, bytes memory data, bytes4 selector) internal {
        (bool success, bytes memory result) = target.call(data);
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(IMerkleAccount.UnknownSelector.selector));
    }

    /// @dev Reads module state through its actual dispatcher rather than inspecting implementation-specific slots.
    function _assertState(
        address target,
        uint256 expectedValue,
        address expectedSender,
        uint256 expectedCallValue,
        address expectedContext
    ) internal view {
        (uint256 value, address sender, uint256 callValue, address context) =
            MerkleAdapterStateCapabilityMock(target).capabilityState();
        assertEq(value, expectedValue);
        assertEq(sender, expectedSender);
        assertEq(callValue, expectedCallValue);
        assertEq(context, expectedContext);
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
