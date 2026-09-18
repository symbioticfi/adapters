// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {CapabilitiesRegistryProposer} from "src/contracts/merkle-adapter/CapabilitiesRegistryProposer.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {ICapabilitiesRegistry} from "src/interfaces/merkle-adapter/ICapabilitiesRegistry.sol";
import {
    MerkleAdapterDelegatorMock,
    MerkleAdapterOracleMock,
    MerkleAdapterVaultMock,
    MerkleAdapterVaultRegistry
} from "test/adapters/MerkleAdapter.t.sol";
import {
    MerkleAdapterRawFallbackCapabilityMock,
    MerkleAdapterSignatureCallerMock,
    MerkleAdapterSignatureCapabilityMock,
    MerkleAdapterStateCapabilityMock
} from "test/mocks/MerkleAdapterCapabilityMocks.sol";
import {Token} from "test/mocks/Token.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {IMigratableEntityProxy} from "@symbioticfi/core/src/interfaces/common/IMigratableEntityProxy.sol";
import {MigratableEntityProxy} from "@symbioticfi/core/src/contracts/common/MigratableEntityProxy.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

contract MerkleAdapterCapabilitiesTest is Test {
    MerkleAdapterVaultRegistry internal vaultFactory;
    AdapterFactory internal adapterFactory;
    MigratablesFactory internal oracleFactory;
    RootRegistry internal rootRegistry;
    CapabilitiesRegistry internal capabilityRegistry;
    CapabilitiesRegistryProposer internal proposer;
    MerkleAdapterVaultMock internal vault;
    MerkleAdapterDelegatorMock internal delegator;
    Token internal asset;
    MerkleAdapter internal adapter;
    MerkleAdapterStateCapabilityMock internal stateCapability;
    MerkleAdapterSignatureCapabilityMock internal signatureCapability;

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
        proposer = new CapabilitiesRegistryProposer(protocolOwner);
        capabilityRegistry = new CapabilitiesRegistry(adapterOwner, address(proposer));
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
                    address(rootRegistry),
                    address(capabilityRegistry)
                )
            )
        );
        adapter = _createAdapter();
        stateCapability = new MerkleAdapterStateCapabilityMock();
        signatureCapability = new MerkleAdapterSignatureCapabilityMock();
        _initCapability(address(stateCapability), _stateSelectors());
        _initCapability(address(signatureCapability), _singleSelector(IERC1271.isValidSignature.selector));
    }

    function test_ConstructorStoresZeroAndNonContractRegistry() public {
        address[2] memory invalidRegistries = [address(0), caller];
        for (uint256 i; i < invalidRegistries.length; ++i) {
            MerkleAdapter uncheckedAdapter = new MerkleAdapter(
                address(vaultFactory),
                address(adapterFactory),
                address(oracleFactory),
                address(rootRegistry),
                invalidRegistries[i]
            );
            assertEq(uncheckedAdapter.CAPABILITIES_REGISTRY(), invalidRegistries[i]);
        }
    }

    /// @dev Registry approval makes a module eligible; the adapter owner's installation enables its selectors.
    function test_AddCapabilityRequiresRegistryApprovalAndOwnerInstallation() public {
        bytes4 selector = MerkleAdapterStateCapabilityMock.capabilityState.selector;
        assertEq(adapter.CAPABILITIES_REGISTRY(), address(capabilityRegistry));
        assertFalse(adapter.isCapability(address(stateCapability)));
        _expectUnknown(address(adapter), abi.encodeWithSelector(selector), selector);

        _setWhitelisted(adapter, address(stateCapability), true);
        assertEq(adapter.capabilityForSelector(selector), address(0));
        _expectUnknown(address(adapter), abi.encodeWithSelector(selector), selector);

        vm.expectEmit(true, false, false, false, address(adapter));
        emit IMerkleAdapter.AddCapability(address(stateCapability));
        _addCapability(adapter, address(stateCapability));

        assertTrue(adapter.isCapability(address(stateCapability)));
        address[] memory capabilities = adapter.getCapabilities();
        assertEq(capabilities.length, 1);
        assertEq(capabilities[0], address(stateCapability));
        bytes4[] memory selectors = _stateSelectors();
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(adapter.capabilityForSelector(selectors[i]), address(stateCapability));
        }
        _assertState(address(adapter), 0, address(0), 0, address(0));
    }

    /// @dev Protocol approval is scoped to the exact proxy and cannot be reused by another adapter.
    function test_AddCapabilityRejectsApprovalForAnotherAdapter() public {
        MerkleAdapter otherAdapter = _createAdapter();
        _setWhitelisted(otherAdapter, address(stateCapability), true);

        vm.expectRevert(IMerkleAdapter.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        adapter.addCapability(address(stateCapability));

        assertEq(adapter.getCapabilities().length, 0);
        _addCapability(otherAdapter, address(stateCapability));
        assertTrue(otherAdapter.isCapability(address(stateCapability)));
        assertFalse(adapter.isCapability(address(stateCapability)));
    }

    /// @dev Unapproved implementations cannot gain access to adapter storage.
    function test_AddCapabilityRejectsUnapprovedModule() public {
        vm.expectRevert(IMerkleAdapter.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        adapter.addCapability(address(stateCapability));

        assertEq(adapter.getCapabilities().length, 0);
        assertEq(
            adapter.capabilityForSelector(MerkleAdapterStateCapabilityMock.setCapabilityValue.selector), address(0)
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
            adapter.addCapability(address(stateCapability));
        }
        assertEq(adapter.getCapabilities().length, 0);
    }

    /// @dev Installing an existing module cannot duplicate its enumeration entry.
    function test_AddCapabilityRejectsDuplicate() public {
        _installStateCapability(adapter);

        vm.expectRevert(IMerkleAdapter.CapabilityAlreadyAdded.selector);
        vm.prank(adapterOwner);
        adapter.addCapability(address(stateCapability));

        assertEq(adapter.getCapabilities().length, 1);
        assertEq(
            adapter.capabilityForSelector(MerkleAdapterStateCapabilityMock.capabilityState.selector),
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

        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.SelectorAlreadyUsed.selector));
        vm.prank(adapterOwner);
        adapter.addCapability(colliding);

        assertEq(adapter.capabilityForSelector(freshSelector), address(0));
        assertEq(adapter.capabilityForSelector(occupiedSelector), address(stateCapability));
        assertFalse(adapter.isCapability(colliding));
        assertEq(adapter.getCapabilities().length, 1);
        _assertState(address(adapter), 0, address(0), 0, address(0));
    }

    /// @dev Native selectors can be registered and removed like any other capability selectors.
    function test_AddCapabilityAcceptsEveryNativeSelectorFromCompiledAbi() public {
        string memory artifact = vm.readFile("out/MerkleAdapter.sol/MerkleAdapter.json");
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

        assertTrue(adapter.isCapability(capability));
        assertEq(adapter.getCapabilities().length, 1);
        assertEq(adapter.getCapabilities()[0], capability);
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(adapter.capabilityForSelector(selectors[i]), capability);
        }
        assertEq(adapter.owner(), adapterOwner);
        assertEq(adapter.vault(), address(vault));

        vm.prank(adapterOwner);
        adapter.removeCapability(capability);

        assertFalse(adapter.isCapability(capability));
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(adapter.capabilityForSelector(selectors[i]), address(0));
        }
        assertEq(adapter.getCapabilities().length, 0);
        assertEq(adapter.owner(), adapterOwner);
        assertEq(adapter.vault(), address(vault));
    }

    /// @dev Registered native reads, writes, and reverts retain their ordinary dispatch and authorization.
    function test_AddCapabilityDoesNotShadowNativeFunctions() public {
        address capability = address(new MerkleAdapterRawFallbackCapabilityMock());
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = adapter.owner.selector;
        selectors[1] = adapter.transferOwnership.selector;
        selectors[2] = adapter.removeCapability.selector;
        selectors[3] = 0x12345678;
        _initCapability(capability, selectors);
        _setWhitelisted(adapter, capability, true);
        _addCapability(adapter, capability);

        bytes memory data = abi.encodeWithSelector(selectors[3], uint256(17));
        (bool success, bytes memory result) = address(adapter).call(data);
        assertTrue(success);
        assertEq(result, data);
        assertEq(adapter.owner(), adapterOwner);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        adapter.transferOwnership(caller);
        assertEq(adapter.owner(), adapterOwner);

        vm.prank(adapterOwner);
        adapter.transferOwnership(caller);
        assertEq(adapter.owner(), caller);
        assertEq(adapter.capabilityForSelector(selectors[1]), capability);

        vm.prank(caller);
        adapter.removeCapability(capability);
        assertFalse(adapter.isCapability(capability));
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(adapter.capabilityForSelector(selectors[i]), address(0));
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
        assertTrue(adapter.isCapability(capability));
        assertEq(adapter.capabilityForSelector(selector), capability);

        address implementation = adapterFactory.implementation(1);
        bytes memory data = abi.encodeCall(MerkleAdapterStateCapabilityMock.setCapabilityValue, (31));
        vm.expectRevert(MigratableEntityProxy.ProxyDeniedAdminAccess.selector);
        vm.prank(adapterOwner);
        IMigratableEntityProxy(address(adapter)).upgradeToAndCall(implementation, data);
        _assertState(address(adapter), 0, address(0), 0, address(0));

        vm.prank(address(adapterFactory));
        IMigratableEntityProxy(address(adapter)).upgradeToAndCall(implementation, data);
        _assertState(address(adapter), 31, address(adapterFactory), 0, address(adapter));
        assertEq(adapter.capabilityForSelector(selector), capability);

        vm.prank(adapterOwner);
        adapter.removeCapability(capability);
        assertFalse(adapter.isCapability(capability));
        assertEq(adapter.capabilityForSelector(selector), address(0));
        assertEq(adapter.getCapabilities().length, 1);
        assertTrue(adapter.isCapability(address(stateCapability)));
    }

    /// @dev Removal clears every selector while retaining unrelated modules.
    function test_RemoveCapabilityClearsSelectorsAndPreservesOtherCapabilities() public {
        _installStateCapability(adapter);
        _setWhitelisted(adapter, address(signatureCapability), true);
        _addCapability(adapter, address(signatureCapability));

        vm.expectEmit(true, false, false, false, address(adapter));
        emit IMerkleAdapter.RemoveCapability(address(stateCapability));
        vm.prank(adapterOwner);
        adapter.removeCapability(address(stateCapability));

        assertFalse(adapter.isCapability(address(stateCapability)));
        bytes4[] memory selectors = _stateSelectors();
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(adapter.capabilityForSelector(selectors[i]), address(0));
            _expectUnknown(address(adapter), abi.encodeWithSelector(selectors[i]), selectors[i]);
        }
        address[] memory capabilities = adapter.getCapabilities();
        assertEq(capabilities.length, 1);
        assertEq(capabilities[0], address(signatureCapability));
        assertTrue(adapter.isCapability(address(signatureCapability)));
        assertEq(adapter.capabilityForSelector(IERC1271.isValidSignature.selector), address(signatureCapability));
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
            adapter.removeCapability(address(stateCapability));
        }
        assertTrue(adapter.isCapability(address(stateCapability)));
        _assertState(address(adapter), 0, address(0), 0, address(0));
    }

    /// @dev Missing and already removed modules cannot corrupt enumeration.
    function test_RemoveCapabilityRejectsMissingModule() public {
        vm.expectRevert(IMerkleAdapter.CapabilityNotAdded.selector);
        vm.prank(adapterOwner);
        adapter.removeCapability(address(stateCapability));

        _installStateCapability(adapter);
        vm.prank(adapterOwner);
        adapter.removeCapability(address(stateCapability));

        vm.expectRevert(IMerkleAdapter.CapabilityNotAdded.selector);
        vm.prank(adapterOwner);
        adapter.removeCapability(address(stateCapability));
        assertEq(adapter.getCapabilities().length, 0);
    }

    /// @dev Revoked protocol approval cannot prevent the adapter owner from uninstalling the module.
    function test_RemoveCapabilityRemainsAvailableAfterApprovalRevocation() public {
        _installStateCapability(adapter);
        _setWhitelisted(adapter, address(stateCapability), false);

        vm.prank(adapterOwner);
        adapter.removeCapability(address(stateCapability));

        assertEq(adapter.getCapabilities().length, 0);
        assertFalse(adapter.isCapability(address(stateCapability)));
        bytes4 selector = MerkleAdapterStateCapabilityMock.capabilityState.selector;
        assertEq(adapter.capabilityForSelector(selector), address(0));
        _expectUnknown(address(adapter), abi.encodeWithSelector(selector), selector);
    }

    /// @dev Freed selectors can be installed from another implementation without erasing namespaced adapter state.
    function test_RemoveCapabilityAllowsSelectorReuseByReplacement() public {
        _installStateCapability(adapter);
        vm.prank(caller);
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue(17);
        vm.prank(adapterOwner);
        adapter.removeCapability(address(stateCapability));

        address replacement = address(new MerkleAdapterStateCapabilityMock());
        _initCapability(replacement, _stateSelectors());
        _setWhitelisted(adapter, replacement, true);
        _addCapability(adapter, replacement);

        assertEq(adapter.capabilityForSelector(MerkleAdapterStateCapabilityMock.capabilityState.selector), replacement);
        assertEq(adapter.getCapabilities().length, 1);
        assertEq(adapter.getCapabilities()[0], replacement);
        _assertState(address(adapter), 17, caller, 0, address(adapter));
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue(23);
        _assertState(address(adapter), 23, address(this), 0, address(adapter));
    }

    /// @dev The module receives the external sender and value and executes in the adapter's balance/storage context.
    function test_FallbackPreservesSenderValueAndAdapterContext() public {
        _installStateCapability(adapter);
        vm.deal(caller, 3 ether);

        vm.prank(caller);
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue{value: 2 ether}(42);

        _assertState(address(adapter), 42, caller, 2 ether, address(adapter));
        _assertState(address(stateCapability), 0, address(0), 0, address(0));
        assertEq(address(adapter).balance, 2 ether);
        assertEq(address(stateCapability).balance, 0);
        assertEq(caller.balance, 1 ether);
    }

    /// @dev A shared implementation keeps writes isolated between adapters and from native adapter state.
    function test_FallbackKeepsNamespacedStateSeparateForTwoAdapters() public {
        MerkleAdapter otherAdapter = _createAdapter();
        _installStateCapability(adapter);
        _installStateCapability(otherAdapter);
        address firstOracle = adapter.oracle();
        address secondOracle = otherAdapter.oracle();
        asset.transfer(address(adapter), 19);

        vm.prank(caller);
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue(111);
        vm.prank(adapterOwner);
        MerkleAdapterStateCapabilityMock(address(otherAdapter)).setCapabilityValue(222);

        _assertState(address(adapter), 111, caller, 0, address(adapter));
        _assertState(address(otherAdapter), 222, adapterOwner, 0, address(otherAdapter));
        _assertState(address(stateCapability), 0, address(0), 0, address(0));
        assertEq(adapter.vault(), address(vault));
        assertEq(otherAdapter.vault(), address(vault));
        assertEq(adapter.owner(), adapterOwner);
        assertEq(otherAdapter.owner(), adapterOwner);
        assertEq(adapter.oracle(), firstOracle);
        assertEq(otherAdapter.oracle(), secondOracle);
        assertEq(adapter.freeAssets(), 19);
        assertEq(otherAdapter.freeAssets(), 0);
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), roleAdmin));
        assertTrue(otherAdapter.hasRole(otherAdapter.DEFAULT_ADMIN_ROLE(), roleAdmin));
    }

    /// @dev A real view callback reaches the adapter address under STATICCALL, including its original protocol caller.
    function test_FallbackSupportsErc1271StaticCallbackAtAdapterAddress() public {
        _setWhitelisted(adapter, address(signatureCapability), true);
        _addCapability(adapter, address(signatureCapability));
        MerkleAdapterSignatureCallerMock callbackCaller = new MerkleAdapterSignatureCallerMock();
        bytes memory signature = abi.encode(address(adapter), address(callbackCaller));

        assertEq(
            callbackCaller.checkSignature(address(adapter), keccak256("merkle adapter callback"), signature),
            IERC1271.isValidSignature.selector
        );
        assertEq(callbackCaller.checkSignature(address(adapter), bytes32(0), signature), bytes4(0xffffffff));
        assertEq(adapter.getCapabilities().length, 1);
    }

    /// @dev Revoking approval leaves an installed static callback active until its owner removes the capability.
    function test_FallbackKeepsRevokedCallbackActiveUntilOwnerRemoval() public {
        _setWhitelisted(adapter, address(signatureCapability), true);
        _addCapability(adapter, address(signatureCapability));
        MerkleAdapterSignatureCallerMock callbackCaller = new MerkleAdapterSignatureCallerMock();
        bytes memory signature = abi.encode(address(adapter), address(callbackCaller));
        bytes32 digest = keccak256("merkle adapter callback");
        assertEq(callbackCaller.checkSignature(address(adapter), digest, signature), IERC1271.isValidSignature.selector);

        _setWhitelisted(adapter, address(signatureCapability), false);

        assertEq(callbackCaller.checkSignature(address(adapter), digest, signature), IERC1271.isValidSignature.selector);
        assertTrue(adapter.isCapability(address(signatureCapability)));
        assertEq(adapter.getCapabilities().length, 1);
        assertEq(adapter.capabilityForSelector(IERC1271.isValidSignature.selector), address(signatureCapability));

        vm.prank(adapterOwner);
        adapter.removeCapability(address(signatureCapability));

        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.UnknownSelector.selector));
        callbackCaller.checkSignature(address(adapter), digest, signature);
        vm.expectRevert(IMerkleAdapter.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        adapter.addCapability(address(signatureCapability));
        assertFalse(adapter.isCapability(address(signatureCapability)));
        assertEq(adapter.getCapabilities().length, 0);
        assertEq(adapter.capabilityForSelector(IERC1271.isValidSignature.selector), address(0));

        _setWhitelisted(adapter, address(signatureCapability), true);
        _addCapability(adapter, address(signatureCapability));
        assertEq(callbackCaller.checkSignature(address(adapter), digest, signature), IERC1271.isValidSignature.selector);
        assertEq(adapter.getCapabilities().length, 1);
    }

    /// @dev Installed writes remain active after revocation, while approval for another adapter cannot permit reinstalling.
    function test_FallbackKeepsRevokedWritesActiveAndScopesReinstallationApproval() public {
        MerkleAdapter otherAdapter = _createAdapter();
        _installStateCapability(adapter);
        _installStateCapability(otherAdapter);
        _setWhitelisted(adapter, address(stateCapability), false);

        vm.prank(caller);
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue(1);
        MerkleAdapterStateCapabilityMock(address(otherAdapter)).setCapabilityValue(2);

        _assertState(address(adapter), 1, caller, 0, address(adapter));
        _assertState(address(otherAdapter), 2, address(this), 0, address(otherAdapter));

        vm.prank(adapterOwner);
        adapter.removeCapability(address(stateCapability));
        vm.expectRevert(IMerkleAdapter.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        adapter.addCapability(address(stateCapability));
        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.UnknownSelector.selector));
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue(3);
        MerkleAdapterStateCapabilityMock(address(otherAdapter)).setCapabilityValue(4);
        _assertState(address(otherAdapter), 4, address(this), 0, address(otherAdapter));

        _setWhitelisted(adapter, address(stateCapability), true);
        _addCapability(adapter, address(stateCapability));
        _assertState(address(adapter), 1, caller, 0, address(adapter));
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue(5);
        _assertState(address(adapter), 5, address(this), 0, address(adapter));
    }

    /// @dev Owner installation and module execution in one multicall preserve the external owner and existing storage.
    function test_MulticallReplacesCapabilityAtomicallyWithoutInitializingState() public {
        _installStateCapability(adapter);
        vm.prank(caller);
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue(17);
        address replacement = address(new MerkleAdapterStateCapabilityMock());
        _initCapability(replacement, _stateSelectors());
        _setWhitelisted(adapter, replacement, true);

        bytes[] memory calls = _replacementCalls(replacement);
        vm.prank(adapterOwner);
        adapter.multicall(calls);

        assertFalse(adapter.isCapability(address(stateCapability)));
        assertTrue(adapter.isCapability(replacement));
        _assertState(address(adapter), 17, caller, 0, address(adapter));

        calls = new bytes[](1);
        calls[0] = abi.encodeCall(MerkleAdapterStateCapabilityMock.setCapabilityValue, (23));
        vm.prank(adapterOwner);
        adapter.multicall(calls);
        _assertState(address(adapter), 23, adapterOwner, 0, address(adapter));
    }

    /// @dev An unauthorized multicall cannot acquire owner permissions through self-delegatecall.
    function test_MulticallPreservesOwnerAuthorization() public {
        _setWhitelisted(adapter, address(stateCapability), true);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(IMerkleAdapter.addCapability, (address(stateCapability)));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        adapter.multicall(calls);

        assertFalse(adapter.isCapability(address(stateCapability)));
        assertEq(adapter.getCapabilities().length, 0);
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
                    ? abi.encodeCall(IMerkleAdapter.addCapability, (capabilities[selected]))
                    : abi.encodeCall(IMerkleAdapter.removeCapability, (capabilities[selected]));
                vm.prank(adapterOwner);
                (bool success,) = address(adapter).call(data);
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
            address(adapter).call(abi.encodeCall(MerkleAdapterStateCapabilityMock.returnRaw, (expected)));

        assertTrue(success);
        assertEq(actual, expected);
    }

    /// @dev Both storage writes and received ETH roll back, while revert bytes survive both delegatecall layers.
    function testFuzz_FallbackForwardsRawRevertDataAndRollsBack(bytes memory expected) public {
        vm.assume(expected.length <= 4096);
        _installStateCapability(adapter);
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue(7);
        vm.deal(caller, 1 ether);

        vm.prank(caller);
        (bool success, bytes memory actual) = address(adapter).call{value: 1 ether}(
            abi.encodeCall(MerkleAdapterStateCapabilityMock.writeThenRevert, (99, expected))
        );

        assertFalse(success);
        assertEq(actual, expected);
        _assertState(address(adapter), 7, address(this), 0, address(adapter));
        assertEq(address(adapter).balance, 0);
        assertEq(caller.balance, 1 ether);
    }

    /// @dev An unknown full selector cannot dispatch to an arbitrary implementation.
    function test_FallbackRejectsUnknownSelector() public {
        _installStateCapability(adapter);
        _expectUnknown(address(adapter), hex"1234567801020304", 0x12345678);
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
            (bool success, bytes memory result) = address(adapter).call(data);
            assertTrue(success);
            assertEq(result, data);
        }
        _expectUnknown(address(adapter), hex"12", 0x12000000);
        _expectUnknown(address(adapter), hex"1234", 0x12340000);
        _expectUnknown(address(adapter), hex"123456", 0x12345600);
    }

    /// @dev Existing plain ETH funding remains available independently of capability routing.
    function test_ReceiveKeepsPlainEthFundingAvailable() public {
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        (bool success, bytes memory result) = address(adapter).call{value: 1 ether}("");

        assertTrue(success);
        assertEq(result.length, 0);
        assertEq(address(adapter).balance, 1 ether);
        assertEq(adapter.getCapabilities().length, 0);
    }

    /// @dev A protocol proposal cannot install code until the curator explicitly accepts it locally.
    function test_AddCapabilityRequiresCuratorAcceptanceAfterProposal() public {
        vm.prank(protocolOwner);
        proposer.setProposedStatus(address(capabilityRegistry), address(adapter), address(stateCapability), true);
        vm.expectRevert(IMerkleAdapter.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        adapter.addCapability(address(stateCapability));
        assertFalse(capabilityRegistry.isAccepted(address(adapter), address(stateCapability)));
        vm.prank(adapterOwner);
        capabilityRegistry.acceptCapability(address(adapter), address(stateCapability));
        _addCapability(adapter, address(stateCapability));
        _assertState(address(adapter), 0, address(0), 0, address(0));
    }

    /// @dev A curator can revoke local consent while leaving existing callbacks available until removal.
    function test_CuratorRevocationPreservesRoutesButBlocksReinstallation() public {
        _installStateCapability(adapter);
        vm.prank(adapterOwner);
        capabilityRegistry.setWhitelistedStatus(address(adapter), address(stateCapability), false);
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue(21);
        _assertState(address(adapter), 21, address(this), 0, address(adapter));
        vm.prank(adapterOwner);
        adapter.removeCapability(address(stateCapability));
        vm.expectRevert(IMerkleAdapter.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        adapter.addCapability(address(stateCapability));

        vm.prank(adapterOwner);
        capabilityRegistry.acceptCapability(address(adapter), address(stateCapability));
        _addCapability(adapter, address(stateCapability));
        _assertState(address(adapter), 21, address(this), 0, address(adapter));
    }

    /// @dev Even after acceptance, changes to the registered bytecode block a new installation.
    function test_AddCapabilityRejectsChangedCodeAfterAcceptance() public {
        _setWhitelisted(adapter, address(stateCapability), true);
        vm.etch(address(stateCapability), hex"60006000fd");
        vm.expectRevert(IMerkleAdapter.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        adapter.addCapability(address(stateCapability));
        assertFalse(adapter.isCapability(address(stateCapability)));
    }

    /// @dev Neither dispatch nor removal asks the proposer; installed routes depend only on local state.
    function test_CallbacksAndRemovalRemainAvailableWithoutProposer() public {
        _installStateCapability(adapter);
        vm.etch(address(proposer), hex"");
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue(31);
        _assertState(address(adapter), 31, address(this), 0, address(adapter));
        vm.prank(adapterOwner);
        adapter.removeCapability(address(stateCapability));
        assertFalse(adapter.isCapability(address(stateCapability)));
        bytes4 selector = MerkleAdapterStateCapabilityMock.capabilityState.selector;
        _expectUnknown(address(adapter), abi.encodeWithSelector(selector), selector);
    }

    /// @dev A proposal sent to another curator's registry cannot authorize this adapter's fixed registry.
    function test_ProposalToAnotherRegistryCannotBeAccepted() public {
        CapabilitiesRegistry otherRegistry = new CapabilitiesRegistry(adapterOwner, address(proposer));
        vm.prank(protocolOwner);
        proposer.setProposedStatus(address(otherRegistry), address(adapter), address(stateCapability), true);
        vm.expectRevert(ICapabilitiesRegistry.CapabilityNotProposed.selector);
        vm.prank(adapterOwner);
        capabilityRegistry.acceptCapability(address(adapter), address(stateCapability));
        vm.expectRevert(IMerkleAdapter.CapabilityNotWhitelisted.selector);
        vm.prank(adapterOwner);
        adapter.addCapability(address(stateCapability));
    }

    /// @dev Factory creation keeps adapter setup independent of capability installation.
    function _createAdapter() internal returns (MerkleAdapter) {
        IMerkleAdapter.InitParams memory params = IMerkleAdapter.InitParams({defaultAdminRoleHolder: roleAdmin});
        return
            MerkleAdapter(
                payable(adapterFactory.create(1, adapterOwner, abi.encode(address(vault), abi.encode(params))))
            );
    }

    /// @dev Publishes a capability's immutable selector set as the registry owner.
    function _initCapability(address capability, bytes4[] memory selectors) internal {
        vm.prank(protocolOwner);
        proposer.initCapability(capability, selectors);
        vm.prank(adapterOwner);
        capabilityRegistry.initCapability(capability, selectors);
    }

    /// @dev Updates approval for exactly one adapter/capability pair.
    function _setWhitelisted(MerkleAdapter target, address capability, bool status) internal {
        vm.prank(protocolOwner);
        proposer.setProposedStatus(address(capabilityRegistry), address(target), capability, status);
        if (status) {
            vm.prank(adapterOwner);
            capabilityRegistry.acceptCapability(address(target), capability);
        }
    }

    /// @dev Installs a previously approved implementation as the adapter owner.
    function _addCapability(MerkleAdapter target, address capability) internal {
        vm.prank(adapterOwner);
        target.addCapability(capability);
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
        calls[0] = abi.encodeCall(IMerkleAdapter.removeCapability, (address(stateCapability)));
        calls[1] = abi.encodeCall(IMerkleAdapter.addCapability, (replacement));
    }

    /// @dev Exercises replacement failure after removal already ran, then checks the original routing and state.
    function _assertReplacementRollback(bool collision) internal {
        _installStateCapability(adapter);
        _setWhitelisted(adapter, address(signatureCapability), true);
        _addCapability(adapter, address(signatureCapability));
        MerkleAdapterStateCapabilityMock(address(adapter)).setCapabilityValue(17);
        address replacement = address(new MerkleAdapterStateCapabilityMock());
        bytes4[] memory selectors = _stateSelectors();
        if (collision) {
            selectors[3] = IERC1271.isValidSignature.selector;
        }
        _initCapability(replacement, selectors);
        if (collision) {
            _setWhitelisted(adapter, replacement, true);
        }
        bytes[] memory calls = _replacementCalls(replacement);
        bytes memory errorData = collision
            ? abi.encodeWithSelector(IMerkleAdapter.SelectorAlreadyUsed.selector)
            : abi.encodeWithSelector(IMerkleAdapter.CapabilityNotWhitelisted.selector);
        vm.expectRevert(errorData);
        vm.prank(adapterOwner);
        adapter.multicall(calls);

        assertTrue(adapter.isCapability(address(stateCapability)));
        assertTrue(adapter.isCapability(address(signatureCapability)));
        assertFalse(adapter.isCapability(replacement));
        assertEq(adapter.getCapabilities().length, 2);
        selectors = _stateSelectors();
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(adapter.capabilityForSelector(selectors[i]), address(stateCapability));
        }
        assertEq(adapter.capabilityForSelector(IERC1271.isValidSignature.selector), address(signatureCapability));
        _assertState(address(adapter), 17, address(this), 0, address(adapter));
    }

    /// @dev Compares enumeration and every registered selector against an independent operation model.
    function _assertRoutingMatchesModel(address[3] memory capabilities, bool[3] memory installed) internal view {
        address[] memory actual = adapter.getCapabilities();
        bool[3] memory seen;
        uint256 expectedCount;
        for (uint256 i; i < capabilities.length; ++i) {
            assertEq(adapter.isCapability(capabilities[i]), installed[i]);
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
            assertEq(adapter.capabilityForSelector(selectors[i]), expectedState);
        }
        assertEq(
            adapter.capabilityForSelector(IERC1271.isValidSignature.selector),
            installed[2] ? capabilities[2] : address(0)
        );
    }

    /// @dev Verifies the public error and original selector rather than only observing a failed call.
    function _expectUnknown(address target, bytes memory data, bytes4 selector) internal {
        (bool success, bytes memory result) = target.call(data);
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(IMerkleAdapter.UnknownSelector.selector));
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
}
