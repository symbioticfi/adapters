// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CapabilitiesRegistryProposer} from "src/contracts/merkle-adapter/CapabilitiesRegistryProposer.sol";
import {ICapabilitiesRegistryProposer} from "src/interfaces/merkle-adapter/ICapabilitiesRegistryProposer.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Test} from "forge-std/Test.sol";

contract CapabilitiesRegistryProposerImplementationMock {}

contract CapabilitiesRegistryProposerTest is Test {
    CapabilitiesRegistryProposer internal _proposer;

    address internal _owner = makeAddr("owner");
    address internal _adapter = makeAddr("adapter");
    address internal _capability;

    function setUp() public {
        _proposer = new CapabilitiesRegistryProposer(_owner);
        _capability = address(new CapabilitiesRegistryProposerImplementationMock());
    }

    function test_ConstructorStoresOwnerAndEmptyState() public view {
        assertEq(_proposer.owner(), _owner);
        _assertUninitialized(_capability);
        assertFalse(_proposer.isProposed(address(this), _adapter, _capability));
    }

    function test_ConstructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CapabilitiesRegistryProposer(address(0));
    }

    function test_InitCapabilityStoresSelectorOrder(uint8 rawCount, uint32 rawFirst, address adapter) public {
        uint256 count = bound(rawCount, 1, 32);
        uint256 first = bound(rawFirst, 1, type(uint32).max - count);
        bytes4[] memory selectors = new bytes4[](count);
        for (uint256 i; i < count; ++i) {
            selectors[i] = bytes4(uint32(first + count - i));
        }

        vm.expectEmit(true, false, false, true, address(_proposer));
        emit ICapabilitiesRegistryProposer.InitCapability(_capability, _capability.codehash, selectors);
        vm.prank(_owner);
        _proposer.initCapability(_capability, selectors);

        assertTrue(_proposer.isInitialized(_capability));
        assertEq(_proposer.capabilityCodeHash(_capability), _capability.codehash);
        _assertSelectors(_capability, selectors);
        assertFalse(_proposer.isProposed(address(this), adapter, _capability));
    }

    function test_InitCapabilityRejectsNonOwner(address caller) public {
        vm.assume(caller != _owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        _proposer.initCapability(_capability, _selectors());
        _assertUninitialized(_capability);
    }

    function test_InitCapabilityRejectsAddressWithoutCode(address capability) public {
        vm.assume(capability.code.length == 0);
        vm.expectRevert(ICapabilitiesRegistryProposer.InvalidCapability.selector);
        vm.prank(_owner);
        _proposer.initCapability(capability, _selectors());
        _assertUninitialized(capability);
    }

    function test_InitCapabilityRejectsZeroAddress() public {
        vm.expectRevert(ICapabilitiesRegistryProposer.InvalidCapability.selector);
        vm.prank(_owner);
        _proposer.initCapability(address(0), _selectors());
        _assertUninitialized(address(0));
    }

    function test_InitCapabilityRejectsEmptySelectors() public {
        vm.expectRevert(ICapabilitiesRegistryProposer.EmptySelectors.selector);
        vm.prank(_owner);
        _proposer.initCapability(_capability, new bytes4[](0));
        _assertUninitialized(_capability);
    }

    function test_InitCapabilityRejectsZeroSelectorAtomically(uint8 rawIndex) public {
        bytes4[] memory selectors = _selectors();
        selectors[bound(rawIndex, 0, selectors.length - 1)] = bytes4(0);

        vm.expectRevert(ICapabilitiesRegistryProposer.InvalidSelector.selector);
        vm.prank(_owner);
        _proposer.initCapability(_capability, selectors);
        _assertUninitialized(_capability);

        _initCapability(_capability);
        _assertSelectors(_capability, _selectors());
    }

    function test_InitCapabilityRejectsDuplicateSelectorsAtomically(bytes4 selector) public {
        vm.assume(selector != bytes4(0));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = selector;
        selectors[1] = selector == bytes4(uint32(1)) ? bytes4(uint32(2)) : bytes4(uint32(1));
        selectors[2] = selector;

        vm.expectRevert(ICapabilitiesRegistryProposer.DuplicateSelector.selector);
        vm.prank(_owner);
        _proposer.initCapability(_capability, selectors);
        _assertUninitialized(_capability);

        _initCapability(_capability);
        _assertSelectors(_capability, _selectors());
    }

    function test_InitCapabilityRejectsIdenticalAndReplacementSelectors() public {
        _initCapability(_capability);

        vm.startPrank(_owner);
        vm.expectRevert(ICapabilitiesRegistryProposer.CapabilityAlreadyInitialized.selector);
        _proposer.initCapability(_capability, _selectors());

        bytes4[] memory replacement = new bytes4[](1);
        replacement[0] = bytes4(uint32(42));
        vm.expectRevert(ICapabilitiesRegistryProposer.CapabilityAlreadyInitialized.selector);
        _proposer.initCapability(_capability, replacement);
        vm.stopPrank();

        _assertSelectors(_capability, _selectors());
    }

    function test_SetProposedStatusRejectsNonOwner(address caller, bool status) public {
        vm.assume(caller != _owner);
        _initCapability(_capability);
        vm.prank(_owner);
        _proposer.setProposedStatus(address(this), _adapter, _capability, !status);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        _proposer.setProposedStatus(address(this), _adapter, _capability, status);

        assertEq(_proposer.isProposed(address(this), _adapter, _capability), !status);
        _assertSelectors(_capability, _selectors());
    }

    function test_SetProposedStatusRejectsUninitializedCapability(address adapter) public {
        vm.expectRevert(ICapabilitiesRegistryProposer.CapabilityNotInitialized.selector);
        vm.prank(_owner);
        _proposer.setProposedStatus(address(this), adapter, _capability, true);

        _assertUninitialized(_capability);
        assertFalse(_proposer.isProposed(address(this), adapter, _capability));
    }

    function test_SetProposedStatusCanRevokeUnknownCapability(address adapter, address capability) public {
        vm.expectEmit(true, true, true, true, address(_proposer));
        emit ICapabilitiesRegistryProposer.SetProposedStatus(address(this), adapter, capability, false);
        vm.prank(_owner);
        _proposer.setProposedStatus(address(this), adapter, capability, false);

        assertFalse(_proposer.isProposed(address(this), adapter, capability));
        _assertUninitialized(capability);
    }

    function test_SetProposedStatusCanRevokeZeroAddresses() public {
        vm.prank(_owner);
        _proposer.setProposedStatus(address(this), address(0), address(0), false);
        assertFalse(_proposer.isProposed(address(this), address(0), address(0)));
        _assertUninitialized(address(0));
    }

    function test_SetProposedStatusScopesAdapterAndImplementation(address otherAdapter) public {
        vm.assume(otherAdapter != _adapter);
        address otherCapability = address(new CapabilitiesRegistryProposerImplementationMock());
        _initCapability(_capability);
        _initCapability(otherCapability);

        vm.startPrank(_owner);
        _proposer.setProposedStatus(address(this), _adapter, _capability, true);
        assertTrue(_proposer.isProposed(address(this), _adapter, _capability));
        assertFalse(_proposer.isProposed(address(this), otherAdapter, _capability));
        assertFalse(_proposer.isProposed(address(this), _adapter, otherCapability));
        assertFalse(_proposer.isProposed(address(this), otherAdapter, otherCapability));

        _proposer.setProposedStatus(address(this), otherAdapter, _capability, true);
        _proposer.setProposedStatus(address(this), _adapter, otherCapability, true);
        _proposer.setProposedStatus(address(this), _adapter, _capability, false);
        vm.stopPrank();

        assertFalse(_proposer.isProposed(address(this), _adapter, _capability));
        assertTrue(_proposer.isProposed(address(this), otherAdapter, _capability));
        assertTrue(_proposer.isProposed(address(this), _adapter, otherCapability));
        assertFalse(_proposer.isProposed(address(this), otherAdapter, otherCapability));
    }

    function test_SetProposedStatusEmitsEvenWhenUnchanged(bool status) public {
        _initCapability(_capability);
        vm.startPrank(_owner);
        for (uint256 i; i < 2; ++i) {
            vm.expectEmit(true, true, true, true, address(_proposer));
            emit ICapabilitiesRegistryProposer.SetProposedStatus(address(this), _adapter, _capability, status);
            _proposer.setProposedStatus(address(this), _adapter, _capability, status);
        }
        vm.stopPrank();

        assertEq(_proposer.isProposed(address(this), _adapter, _capability), status);
    }

    function test_RevocationAndReapprovalPreserveSelectors() public {
        _initCapability(_capability);

        vm.startPrank(_owner);
        _proposer.setProposedStatus(address(this), _adapter, _capability, true);
        _proposer.setProposedStatus(address(this), _adapter, _capability, false);
        assertFalse(_proposer.isProposed(address(this), _adapter, _capability));
        assertTrue(_proposer.isInitialized(_capability));
        _assertSelectors(_capability, _selectors());

        vm.expectRevert(ICapabilitiesRegistryProposer.CapabilityAlreadyInitialized.selector);
        _proposer.initCapability(_capability, _selectors());

        _proposer.setProposedStatus(address(this), _adapter, _capability, true);
        vm.stopPrank();

        assertTrue(_proposer.isProposed(address(this), _adapter, _capability));
        _assertSelectors(_capability, _selectors());
    }

    function test_OwnershipTransferChangesAuthorityWithoutChangingSelectors(address newOwner) public {
        vm.assume(newOwner != address(0) && newOwner != _owner);
        _initCapability(_capability);
        vm.prank(_owner);
        _proposer.setProposedStatus(address(this), _adapter, _capability, true);

        vm.prank(_owner);
        _proposer.transferOwnership(newOwner);

        address otherCapability = address(new CapabilitiesRegistryProposerImplementationMock());
        vm.startPrank(_owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _owner));
        _proposer.initCapability(otherCapability, _selectors());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _owner));
        _proposer.setProposedStatus(address(this), _adapter, _capability, false);
        vm.stopPrank();

        vm.startPrank(newOwner);
        vm.expectRevert(ICapabilitiesRegistryProposer.CapabilityAlreadyInitialized.selector);
        _proposer.initCapability(_capability, _selectors());
        _proposer.setProposedStatus(address(this), _adapter, _capability, false);
        _proposer.initCapability(otherCapability, _selectors());
        _proposer.setProposedStatus(address(this), _adapter, otherCapability, true);
        vm.stopPrank();

        assertFalse(_proposer.isProposed(address(this), _adapter, _capability));
        assertTrue(_proposer.isProposed(address(this), _adapter, otherCapability));
        _assertSelectors(_capability, _selectors());
        _assertSelectors(otherCapability, _selectors());
    }

    function test_GetCapabilitySelectorsReturnsEmptyForUnknown(address capability) public view {
        _assertUninitialized(capability);
    }

    function test_GetCapabilitySelectorsReturnsIndependentCopy() public {
        _initCapability(_capability);
        bytes4[] memory returnedSelectors = _proposer.getCapabilitySelectors(_capability);
        returnedSelectors[0] = bytes4(0);
        _assertSelectors(_capability, _selectors());
    }

    function test_ProposalCannotBeReusedByAnotherRegistry() public {
        address otherRegistry = address(new CapabilitiesRegistryProposerImplementationMock());
        _initCapability(_capability);
        vm.startPrank(_owner);
        _proposer.setProposedStatus(address(this), _adapter, _capability, true);
        assertFalse(_proposer.isProposed(otherRegistry, _adapter, _capability));
        _proposer.setProposedStatus(otherRegistry, _adapter, _capability, true);
        _proposer.setProposedStatus(address(this), _adapter, _capability, false);
        vm.stopPrank();
        assertFalse(_proposer.isProposed(address(this), _adapter, _capability));
        assertTrue(_proposer.isProposed(otherRegistry, _adapter, _capability));
    }

    function test_ProposalRejectsRegistryWithoutCode(address registry) public {
        vm.assume(registry.code.length == 0);
        _initCapability(_capability);
        vm.expectRevert(ICapabilitiesRegistryProposer.InvalidRegistry.selector);
        vm.prank(_owner);
        _proposer.setProposedStatus(registry, _adapter, _capability, true);
        assertFalse(_proposer.isProposed(registry, _adapter, _capability));
    }

    function test_ChangedCodeCannotBeProposedButCanBeWithdrawn(bool deleted) public {
        _initCapability(_capability);
        bytes32 originalHash = _capability.codehash;
        vm.prank(_owner);
        _proposer.setProposedStatus(address(this), _adapter, _capability, true);
        vm.etch(_capability, deleted ? bytes("") : bytes(hex"60006000fd"));
        vm.startPrank(_owner);
        vm.expectRevert(ICapabilitiesRegistryProposer.InvalidCapabilityCode.selector);
        _proposer.setProposedStatus(address(this), _adapter, _capability, true);
        vm.expectRevert(ICapabilitiesRegistryProposer.CapabilityAlreadyInitialized.selector);
        _proposer.initCapability(_capability, _selectors());
        _proposer.setProposedStatus(address(this), _adapter, _capability, false);
        vm.stopPrank();
        assertEq(_proposer.capabilityCodeHash(_capability), originalHash);
        _assertSelectors(_capability, _selectors());
        assertFalse(_proposer.isProposed(address(this), _adapter, _capability));
    }

    function test_WithdrawalDoesNotRequireRegistryCode() public {
        address registry = address(new CapabilitiesRegistryProposerImplementationMock());
        _initCapability(_capability);
        vm.prank(_owner);
        _proposer.setProposedStatus(registry, _adapter, _capability, true);
        vm.etch(registry, hex"");
        vm.prank(_owner);
        _proposer.setProposedStatus(registry, _adapter, _capability, false);
        assertFalse(_proposer.isProposed(registry, _adapter, _capability));
    }

    /// @dev Registers the fixture selectors without granting approval to any adapter.
    function _initCapability(address capability) internal {
        vm.prank(_owner);
        _proposer.initCapability(capability, _selectors());
    }

    /// @dev Returns a deliberately unsorted selector list to check exact order preservation.
    function _selectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = bytes4(uint32(3));
        selectors[1] = bytes4(uint32(1));
        selectors[2] = bytes4(uint32(2));
    }

    /// @dev Checks that rejected or absent initialization leaves both initialization views empty.
    function _assertUninitialized(address capability) internal view {
        assertFalse(_proposer.isInitialized(capability));
        assertEq(_proposer.getCapabilitySelectors(capability).length, 0);
    }

    /// @dev Checks every selector and its position in the configured list.
    function _assertSelectors(address capability, bytes4[] memory expected) internal view {
        bytes4[] memory actual = _proposer.getCapabilitySelectors(capability);
        assertEq(actual.length, expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(actual[i], expected[i]);
        }
    }
}
