// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CapabilitiesRegistry} from "src/contracts/merkle_adapter/CapabilitiesRegistry.sol";
import {CapabilitiesRegistryProposer} from "src/contracts/merkle_adapter/CapabilitiesRegistryProposer.sol";
import {ICapabilitiesRegistry} from "src/interfaces/merkle_adapter/ICapabilitiesRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Test} from "forge-std/Test.sol";

/// @dev Any execution of proposed code must fail; registration and acceptance only inspect its manifest.
contract ProposedCapabilityMock {
    fallback() external {
        revert();
    }
}

contract CapabilitiesRegistryTest is Test {
    CapabilitiesRegistry internal _registry;
    CapabilitiesRegistryProposer internal _proposer;
    address internal _curator = makeAddr("curator");
    address internal _protocol = makeAddr("protocol");
    address internal _adapter = makeAddr("adapter");
    address internal _capability;

    function setUp() public {
        _proposer = new CapabilitiesRegistryProposer(_protocol);
        _registry = new CapabilitiesRegistry(_curator, address(_proposer));
        _capability = address(new ProposedCapabilityMock());
        vm.prank(_protocol);
        _proposer.initCapability(_capability, _selectors());
    }

    function test_ConstructorStoresOwnerProposerAndEmptyState() public view {
        assertEq(_registry.owner(), _curator);
        assertEq(_registry.PROPOSER(), address(_proposer));
        _assertEmpty();
    }

    function test_ConstructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CapabilitiesRegistry(address(0), address(_proposer));
    }

    function test_ConstructorStoresMissingProposer(address proposer) public {
        vm.assume(proposer.code.length == 0);
        CapabilitiesRegistry registry = new CapabilitiesRegistry(_curator, proposer);
        assertEq(registry.PROPOSER(), proposer);
    }

    function test_ProposalCannotAcceptOnCuratorsBehalf() public {
        _propose(_registry, _adapter, true);
        _assertEmpty();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _protocol));
        vm.prank(_protocol);
        _registry.acceptCapability(_adapter, _capability);
        _assertEmpty();
    }

    function test_AcceptCopiesExactCodeAndSelectorsAndEmits() public {
        _propose(_registry, _adapter, true);
        vm.expectEmit(true, false, false, true, address(_registry));
        emit ICapabilitiesRegistry.InitCapability(_capability, _capability.codehash, _selectors());
        vm.expectEmit(true, true, false, true, address(_registry));
        emit ICapabilitiesRegistry.SetWhitelistedStatus(_adapter, _capability, true);
        _accept(_adapter);

        assertTrue(_registry.isAccepted(_adapter, _capability));
        assertTrue(_registry.isWhitelisted(_adapter, _capability));
        _assertManifest();
    }

    function test_AllCuratorMutationsRejectNonOwner(address caller, bool status) public {
        vm.assume(caller != _curator);
        _propose(_registry, _adapter, true);
        bytes memory errorData = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
        vm.startPrank(caller);
        vm.expectRevert(errorData);
        _registry.initCapability(_capability, _selectors());
        vm.expectRevert(errorData);
        _registry.acceptCapability(_adapter, _capability);
        vm.expectRevert(errorData);
        _registry.setWhitelistedStatus(_adapter, _capability, status);
        vm.stopPrank();
        _assertEmpty();
    }

    function test_AcceptWithoutProposalRollsBackManifest() public {
        vm.expectRevert(ICapabilitiesRegistry.CapabilityNotProposed.selector);
        _accept(_adapter);
        _assertEmpty();
    }

    function test_WithdrawnProposalCannotBeAccepted() public {
        _propose(_registry, _adapter, true);
        _propose(_registry, _adapter, false);
        vm.expectRevert(ICapabilitiesRegistry.CapabilityNotProposed.selector);
        _accept(_adapter);
        _assertEmpty();
    }

    function test_AcceptRejectsUnregisteredCode() public {
        address otherCapability = address(new ProposedCapabilityMock());
        vm.expectRevert(ICapabilitiesRegistry.InvalidCapabilityCode.selector);
        vm.prank(_curator);
        _registry.acceptCapability(_adapter, otherCapability);
        assertFalse(_registry.isInitialized(otherCapability));
    }

    function test_ProposalIsScopedToRegistryAndAdapter(address otherAdapter) public {
        vm.assume(otherAdapter != _adapter);
        CapabilitiesRegistry otherRegistry = new CapabilitiesRegistry(_curator, address(_proposer));
        _propose(_registry, _adapter, true);
        _accept(_adapter);

        vm.startPrank(_curator);
        vm.expectRevert(ICapabilitiesRegistry.CapabilityNotProposed.selector);
        otherRegistry.acceptCapability(_adapter, _capability);
        vm.expectRevert(ICapabilitiesRegistry.CapabilityNotProposed.selector);
        _registry.acceptCapability(otherAdapter, _capability);
        vm.stopPrank();
        assertFalse(otherRegistry.isInitialized(_capability));
        assertFalse(_registry.isAccepted(otherAdapter, _capability));
        assertTrue(_registry.isWhitelisted(_adapter, _capability));

        _propose(otherRegistry, _adapter, true);
        vm.prank(_curator);
        otherRegistry.acceptCapability(_adapter, _capability);
        _propose(_registry, otherAdapter, true);
        _accept(otherAdapter);
        assertTrue(otherRegistry.isWhitelisted(_adapter, _capability));
        assertTrue(_registry.isWhitelisted(otherAdapter, _capability));
    }

    function test_ImplementationWithIdenticalBytecodeNeedsSeparateProposal() public {
        address otherCapability = address(new ProposedCapabilityMock());
        assertEq(otherCapability.codehash, _capability.codehash);
        vm.prank(_protocol);
        _proposer.initCapability(otherCapability, _selectors());
        _propose(_registry, _adapter, true);

        vm.expectRevert(ICapabilitiesRegistry.CapabilityNotProposed.selector);
        vm.prank(_curator);
        _registry.acceptCapability(_adapter, otherCapability);
        assertFalse(_registry.isInitialized(otherCapability));
    }

    function test_InitCapabilityPreservesExplicitTwoStepAcceptance() public {
        vm.prank(_curator);
        _registry.initCapability(_capability, _selectors());
        _assertManifest();
        assertFalse(_registry.isAccepted(_adapter, _capability));

        vm.expectRevert(ICapabilitiesRegistry.CapabilityNotProposed.selector);
        vm.prank(_curator);
        _registry.setWhitelistedStatus(_adapter, _capability, true);

        _propose(_registry, _adapter, true);
        vm.prank(_curator);
        _registry.setWhitelistedStatus(_adapter, _capability, true);
        assertTrue(_registry.isWhitelisted(_adapter, _capability));
    }

    function test_InitCapabilityRejectsDifferentSelectors(uint8 mutation) public {
        bytes4[] memory selectors = _selectors();
        mutation = uint8(bound(mutation, 0, 4));
        if (mutation == 0) {
            selectors = new bytes4[](0);
        } else if (mutation == 1) {
            selectors[0] = bytes4(0);
        } else if (mutation == 2) {
            selectors[1] = selectors[0];
        } else if (mutation == 3) {
            (selectors[0], selectors[1]) = (selectors[1], selectors[0]);
        } else {
            selectors[0] = bytes4(keccak256("different()"));
        }
        vm.expectRevert(ICapabilitiesRegistry.InvalidCapabilitySelectors.selector);
        vm.prank(_curator);
        _registry.initCapability(_capability, selectors);
        _assertEmpty();
    }

    function test_ManifestCannotChangeAfterAcceptanceOrRevocation() public {
        _propose(_registry, _adapter, true);
        _accept(_adapter);
        vm.startPrank(_curator);
        vm.expectRevert(ICapabilitiesRegistry.CapabilityAlreadyInitialized.selector);
        _registry.initCapability(_capability, _selectors());
        _registry.setWhitelistedStatus(_adapter, _capability, false);
        vm.expectRevert(ICapabilitiesRegistry.CapabilityAlreadyInitialized.selector);
        _registry.initCapability(_capability, new bytes4[](0));
        vm.stopPrank();
        _assertManifest();
    }

    function test_ChangedCodeCannotBeAccepted(bool deleted) public {
        _propose(_registry, _adapter, true);
        vm.etch(_capability, deleted ? bytes("") : bytes(hex"60006000fd"));
        vm.expectRevert(ICapabilitiesRegistry.InvalidCapabilityCode.selector);
        _accept(_adapter);
        _assertEmpty();
    }

    function test_ChangedCodeBlocksFutureInstallationsAndReacceptance(bool deleted) public {
        _propose(_registry, _adapter, true);
        _accept(_adapter);
        bytes32 acceptedCodeHash = _capability.codehash;
        vm.etch(_capability, deleted ? bytes("") : bytes(hex"60006000fd"));
        assertFalse(_registry.isWhitelisted(_adapter, _capability));
        assertTrue(_registry.isAccepted(_adapter, _capability));
        assertEq(_registry.capabilityCodeHash(_capability), acceptedCodeHash);
        vm.expectRevert(ICapabilitiesRegistry.InvalidCapabilityCode.selector);
        _accept(_adapter);

        vm.prank(_curator);
        _registry.setWhitelistedStatus(_adapter, _capability, false);
        assertFalse(_registry.isAccepted(_adapter, _capability));
    }

    function test_WithdrawalPreservesAcceptanceButBlocksInstallation() public {
        _propose(_registry, _adapter, true);
        _accept(_adapter);
        _propose(_registry, _adapter, false);
        assertTrue(_registry.isAccepted(_adapter, _capability));
        assertFalse(_registry.isWhitelisted(_adapter, _capability));
        _assertManifest();
        vm.expectRevert(ICapabilitiesRegistry.CapabilityNotProposed.selector);
        _accept(_adapter);

        // Reproposal of the same immutable code does not erase the curator's earlier consent.
        _propose(_registry, _adapter, true);
        assertTrue(_registry.isWhitelisted(_adapter, _capability));
    }

    function test_ReproposalCannotRestoreRevokedCuratorConsent() public {
        _propose(_registry, _adapter, true);
        _accept(_adapter);
        vm.prank(_curator);
        _registry.setWhitelistedStatus(_adapter, _capability, false);
        _propose(_registry, _adapter, false);
        _propose(_registry, _adapter, true);
        assertFalse(_registry.isAccepted(_adapter, _capability));
        assertFalse(_registry.isWhitelisted(_adapter, _capability));
        _accept(_adapter);
        assertTrue(_registry.isWhitelisted(_adapter, _capability));
    }

    function test_RevocationAndManifestReadsDoNotDependOnProposerAvailability() public {
        _propose(_registry, _adapter, true);
        _accept(_adapter);
        vm.etch(address(_proposer), hex"");
        vm.prank(_curator);
        _registry.setWhitelistedStatus(_adapter, _capability, false);
        assertFalse(_registry.isWhitelisted(_adapter, _capability));
        _assertManifest();
    }

    function test_SetWhitelistedStatusRequiresInitializedManifest() public {
        _propose(_registry, _adapter, true);
        vm.expectRevert(ICapabilitiesRegistry.CapabilityNotInitialized.selector);
        vm.prank(_curator);
        _registry.setWhitelistedStatus(_adapter, _capability, true);
        _assertEmpty();
    }

    function test_CuratorCanRevokeUnknownPair(address adapter, address capability) public {
        vm.expectEmit(true, true, false, true, address(_registry));
        emit ICapabilitiesRegistry.SetWhitelistedStatus(adapter, capability, false);
        vm.prank(_curator);
        _registry.setWhitelistedStatus(adapter, capability, false);
        assertFalse(_registry.isAccepted(adapter, capability));
        assertFalse(_registry.isWhitelisted(adapter, capability));
    }

    function test_OwnerTransferPreservesManifestAndChangesAcceptanceAuthority(address newOwner) public {
        vm.assume(newOwner != address(0) && newOwner != _curator);
        _propose(_registry, _adapter, true);
        _accept(_adapter);
        vm.prank(_curator);
        _registry.transferOwnership(newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _curator));
        vm.prank(_curator);
        _registry.setWhitelistedStatus(_adapter, _capability, false);
        vm.prank(newOwner);
        _registry.setWhitelistedStatus(_adapter, _capability, false);
        assertFalse(_registry.isWhitelisted(_adapter, _capability));
        _assertManifest();
    }

    function test_ManifestsAreIndependentAcrossCuratorRegistries() public {
        CapabilitiesRegistry otherRegistry = new CapabilitiesRegistry(_curator, address(_proposer));
        _propose(_registry, _adapter, true);
        _accept(_adapter);
        assertFalse(otherRegistry.isInitialized(_capability));
        bytes4[] memory selectors = _registry.getCapabilitySelectors(_capability);
        selectors[0] = bytes4(0);
        _assertManifest();
    }

    /// @dev Compare installation eligibility with an independent model across interleaved governance operations.
    function testFuzz_ConsentAndCodeHashStateMachine(uint256 operations) public {
        bool accepted;
        bool proposed;
        bool codeMatches = true;
        bytes memory originalCode = _capability.code;
        bytes32 originalHash = _capability.codehash;
        for (uint256 i; i < 32; ++i) {
            uint256 operation = (operations >> (i * 8)) & 7;
            if (operation == 0) {
                if (!codeMatches) {
                    vm.etch(_capability, originalCode);
                    codeMatches = true;
                }
                _propose(_registry, _adapter, true);
                proposed = true;
            } else if (operation == 1) {
                _propose(_registry, _adapter, false);
                proposed = false;
            } else if (operation < 4) {
                if (proposed && codeMatches) {
                    _accept(_adapter);
                    accepted = true;
                } else {
                    vm.prank(_curator);
                    (bool success,) =
                        address(_registry).call(abi.encodeCall(_registry.acceptCapability, (_adapter, _capability)));
                    assertFalse(success);
                }
            } else if (operation == 4) {
                vm.prank(_curator);
                _registry.setWhitelistedStatus(_adapter, _capability, false);
                accepted = false;
            } else if (operation == 5) {
                vm.etch(_capability, hex"60006000fd");
                codeMatches = false;
            } else {
                vm.etch(_capability, originalCode);
                codeMatches = true;
            }
            assertEq(_registry.isAccepted(_adapter, _capability), accepted);
            assertEq(_registry.isWhitelisted(_adapter, _capability), accepted && proposed && codeMatches);
            if (_registry.isInitialized(_capability)) {
                assertEq(_registry.capabilityCodeHash(_capability), originalHash);
                assertEq(abi.encode(_registry.getCapabilitySelectors(_capability)), abi.encode(_selectors()));
            }
        }
    }

    function _propose(CapabilitiesRegistry registry, address adapter, bool status) internal {
        vm.prank(_protocol);
        _proposer.setProposedStatus(address(registry), adapter, _capability, status);
    }

    function _accept(address adapter) internal {
        vm.prank(_curator);
        _registry.acceptCapability(adapter, _capability);
    }

    function _assertEmpty() internal view {
        assertFalse(_registry.isInitialized(_capability));
        assertFalse(_registry.isAccepted(_adapter, _capability));
        assertFalse(_registry.isWhitelisted(_adapter, _capability));
        assertEq(_registry.capabilityCodeHash(_capability), bytes32(0));
        assertEq(_registry.getCapabilitySelectors(_capability).length, 0);
    }

    function _assertManifest() internal view {
        assertTrue(_registry.isInitialized(_capability));
        assertEq(_registry.capabilityCodeHash(_capability), _capability.codehash);
        assertEq(abi.encode(_registry.getCapabilitySelectors(_capability)), abi.encode(_selectors()));
    }

    function _selectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("callback(uint256)"));
        selectors[1] = bytes4(keccak256("isValidSignature(bytes32,bytes)"));
    }
}
