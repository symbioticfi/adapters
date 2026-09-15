// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CapabilityRegistry} from "src/contracts/merkle_adapter/CapabilityRegistry.sol";
import {ICapabilityRegistry} from "src/interfaces/merkle_adapter/ICapabilityRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Test} from "forge-std/Test.sol";

contract CapabilityRegistryImplementationMock {}

contract CapabilityRegistryTest is Test {
    CapabilityRegistry internal _registry;

    address internal _owner = makeAddr("owner");
    address internal _adapter = makeAddr("adapter");
    address internal _capability;

    function setUp() public {
        _registry = new CapabilityRegistry(_owner);
        _capability = address(new CapabilityRegistryImplementationMock());
    }

    function test_ConstructorStoresOwnerAndEmptyState() public view {
        assertEq(_registry.owner(), _owner);
        _assertUninitialized(_capability);
        assertFalse(_registry.isWhitelisted(_adapter, _capability));
    }

    function test_ConstructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CapabilityRegistry(address(0));
    }

    function test_InitCapabilityStoresSelectorOrder(uint8 rawCount, uint32 rawFirst, address adapter) public {
        uint256 count = bound(rawCount, 1, 32);
        uint256 first = bound(rawFirst, 1, type(uint32).max - count);
        bytes4[] memory selectors = new bytes4[](count);
        for (uint256 i; i < count; ++i) {
            selectors[i] = bytes4(uint32(first + count - i));
        }

        vm.expectEmit(true, false, false, true, address(_registry));
        emit ICapabilityRegistry.InitCapability(_capability, selectors);
        vm.prank(_owner);
        _registry.initCapability(_capability, selectors);

        assertTrue(_registry.isInitialized(_capability));
        _assertSelectors(_capability, selectors);
        assertFalse(_registry.isWhitelisted(adapter, _capability));
    }

    function test_InitCapabilityRejectsNonOwner(address caller) public {
        vm.assume(caller != _owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        _registry.initCapability(_capability, _selectors());
        _assertUninitialized(_capability);
    }

    function test_InitCapabilityRejectsAddressWithoutCode(address capability) public {
        vm.assume(capability.code.length == 0);
        vm.expectRevert(ICapabilityRegistry.InvalidCapability.selector);
        vm.prank(_owner);
        _registry.initCapability(capability, _selectors());
        _assertUninitialized(capability);
    }

    function test_InitCapabilityRejectsZeroAddress() public {
        vm.expectRevert(ICapabilityRegistry.InvalidCapability.selector);
        vm.prank(_owner);
        _registry.initCapability(address(0), _selectors());
        _assertUninitialized(address(0));
    }

    function test_InitCapabilityRejectsEmptySelectors() public {
        vm.expectRevert(ICapabilityRegistry.EmptySelectors.selector);
        vm.prank(_owner);
        _registry.initCapability(_capability, new bytes4[](0));
        _assertUninitialized(_capability);
    }

    function test_InitCapabilityRejectsZeroSelectorAtomically(uint8 rawIndex) public {
        bytes4[] memory selectors = _selectors();
        selectors[bound(rawIndex, 0, selectors.length - 1)] = bytes4(0);

        vm.expectRevert(ICapabilityRegistry.InvalidSelector.selector);
        vm.prank(_owner);
        _registry.initCapability(_capability, selectors);
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

        vm.expectRevert(ICapabilityRegistry.DuplicateSelector.selector);
        vm.prank(_owner);
        _registry.initCapability(_capability, selectors);
        _assertUninitialized(_capability);

        _initCapability(_capability);
        _assertSelectors(_capability, _selectors());
    }

    function test_InitCapabilityRejectsIdenticalAndReplacementSelectors() public {
        _initCapability(_capability);

        vm.startPrank(_owner);
        vm.expectRevert(ICapabilityRegistry.CapabilityAlreadyInitialized.selector);
        _registry.initCapability(_capability, _selectors());

        bytes4[] memory replacement = new bytes4[](1);
        replacement[0] = bytes4(uint32(42));
        vm.expectRevert(ICapabilityRegistry.CapabilityAlreadyInitialized.selector);
        _registry.initCapability(_capability, replacement);
        vm.stopPrank();

        _assertSelectors(_capability, _selectors());
    }

    function test_SetWhitelistedStatusRejectsNonOwner(address caller, bool status) public {
        vm.assume(caller != _owner);
        _initCapability(_capability);
        vm.prank(_owner);
        _registry.setWhitelistedStatus(_adapter, _capability, !status);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        _registry.setWhitelistedStatus(_adapter, _capability, status);

        assertEq(_registry.isWhitelisted(_adapter, _capability), !status);
        _assertSelectors(_capability, _selectors());
    }

    function test_SetWhitelistedStatusRejectsUninitializedCapability(address adapter) public {
        vm.expectRevert(ICapabilityRegistry.CapabilityNotInitialized.selector);
        vm.prank(_owner);
        _registry.setWhitelistedStatus(adapter, _capability, true);

        _assertUninitialized(_capability);
        assertFalse(_registry.isWhitelisted(adapter, _capability));
    }

    function test_SetWhitelistedStatusCanRevokeUnknownCapability(address adapter, address capability) public {
        vm.expectEmit(true, true, false, true, address(_registry));
        emit ICapabilityRegistry.SetWhitelistedStatus(adapter, capability, false);
        vm.prank(_owner);
        _registry.setWhitelistedStatus(adapter, capability, false);

        assertFalse(_registry.isWhitelisted(adapter, capability));
        _assertUninitialized(capability);
    }

    function test_SetWhitelistedStatusCanRevokeZeroAddresses() public {
        vm.prank(_owner);
        _registry.setWhitelistedStatus(address(0), address(0), false);
        assertFalse(_registry.isWhitelisted(address(0), address(0)));
        _assertUninitialized(address(0));
    }

    function test_SetWhitelistedStatusScopesAdapterAndImplementation(address otherAdapter) public {
        vm.assume(otherAdapter != _adapter);
        address otherCapability = address(new CapabilityRegistryImplementationMock());
        _initCapability(_capability);
        _initCapability(otherCapability);

        vm.startPrank(_owner);
        _registry.setWhitelistedStatus(_adapter, _capability, true);
        assertTrue(_registry.isWhitelisted(_adapter, _capability));
        assertFalse(_registry.isWhitelisted(otherAdapter, _capability));
        assertFalse(_registry.isWhitelisted(_adapter, otherCapability));
        assertFalse(_registry.isWhitelisted(otherAdapter, otherCapability));

        _registry.setWhitelistedStatus(otherAdapter, _capability, true);
        _registry.setWhitelistedStatus(_adapter, otherCapability, true);
        _registry.setWhitelistedStatus(_adapter, _capability, false);
        vm.stopPrank();

        assertFalse(_registry.isWhitelisted(_adapter, _capability));
        assertTrue(_registry.isWhitelisted(otherAdapter, _capability));
        assertTrue(_registry.isWhitelisted(_adapter, otherCapability));
        assertFalse(_registry.isWhitelisted(otherAdapter, otherCapability));
    }

    function test_SetWhitelistedStatusEmitsEvenWhenUnchanged(bool status) public {
        _initCapability(_capability);
        vm.startPrank(_owner);
        for (uint256 i; i < 2; ++i) {
            vm.expectEmit(true, true, false, true, address(_registry));
            emit ICapabilityRegistry.SetWhitelistedStatus(_adapter, _capability, status);
            _registry.setWhitelistedStatus(_adapter, _capability, status);
        }
        vm.stopPrank();

        assertEq(_registry.isWhitelisted(_adapter, _capability), status);
    }

    function test_RevocationAndReapprovalPreserveSelectors() public {
        _initCapability(_capability);

        vm.startPrank(_owner);
        _registry.setWhitelistedStatus(_adapter, _capability, true);
        _registry.setWhitelistedStatus(_adapter, _capability, false);
        assertFalse(_registry.isWhitelisted(_adapter, _capability));
        assertTrue(_registry.isInitialized(_capability));
        _assertSelectors(_capability, _selectors());

        vm.expectRevert(ICapabilityRegistry.CapabilityAlreadyInitialized.selector);
        _registry.initCapability(_capability, _selectors());

        _registry.setWhitelistedStatus(_adapter, _capability, true);
        vm.stopPrank();

        assertTrue(_registry.isWhitelisted(_adapter, _capability));
        _assertSelectors(_capability, _selectors());
    }

    function test_OwnershipTransferChangesAuthorityWithoutChangingSelectors(address newOwner) public {
        vm.assume(newOwner != address(0) && newOwner != _owner);
        _initCapability(_capability);
        vm.prank(_owner);
        _registry.setWhitelistedStatus(_adapter, _capability, true);

        vm.prank(_owner);
        _registry.transferOwnership(newOwner);

        address otherCapability = address(new CapabilityRegistryImplementationMock());
        vm.startPrank(_owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _owner));
        _registry.initCapability(otherCapability, _selectors());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _owner));
        _registry.setWhitelistedStatus(_adapter, _capability, false);
        vm.stopPrank();

        vm.startPrank(newOwner);
        vm.expectRevert(ICapabilityRegistry.CapabilityAlreadyInitialized.selector);
        _registry.initCapability(_capability, _selectors());
        _registry.setWhitelistedStatus(_adapter, _capability, false);
        _registry.initCapability(otherCapability, _selectors());
        _registry.setWhitelistedStatus(_adapter, otherCapability, true);
        vm.stopPrank();

        assertFalse(_registry.isWhitelisted(_adapter, _capability));
        assertTrue(_registry.isWhitelisted(_adapter, otherCapability));
        _assertSelectors(_capability, _selectors());
        _assertSelectors(otherCapability, _selectors());
    }

    function test_GetCapabilitySelectorsReturnsEmptyForUnknown(address capability) public view {
        _assertUninitialized(capability);
    }

    function test_GetCapabilitySelectorsReturnsIndependentCopy() public {
        _initCapability(_capability);
        bytes4[] memory returnedSelectors = _registry.getCapabilitySelectors(_capability);
        returnedSelectors[0] = bytes4(0);
        _assertSelectors(_capability, _selectors());
    }

    /// @dev Registers the fixture selectors without granting approval to any adapter.
    function _initCapability(address capability) internal {
        vm.prank(_owner);
        _registry.initCapability(capability, _selectors());
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
        assertFalse(_registry.isInitialized(capability));
        assertEq(_registry.getCapabilitySelectors(capability).length, 0);
    }

    /// @dev Checks every selector and its position in the configured list.
    function _assertSelectors(address capability, bytes4[] memory expected) internal view {
        bytes4[] memory actual = _registry.getCapabilitySelectors(capability);
        assertEq(actual.length, expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(actual[i], expected[i]);
        }
    }
}
