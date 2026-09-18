// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {ICapabilitiesRegistry} from "src/interfaces/merkle-adapter/ICapabilitiesRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

contract RegistryCapabilityMock {}

contract CapabilitiesRegistryTest is Test {
    address internal registry;
    address internal capability;
    address internal owner = makeAddr("owner");
    address internal adapter = makeAddr("adapter");

    function setUp() public {
        registry = address(new CapabilitiesRegistry(owner));
        capability = address(new RegistryCapabilityMock());
    }

    function test_WhitelistReplacesSelectors(bytes4[] memory first, bytes4[] memory second) public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit ICapabilitiesRegistry.WhitelistCapability(adapter, capability, first);
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, capability, first);
        assertEq(
            abi.encode(ICapabilitiesRegistry(registry).getCapabilitySelectors(adapter, capability)), abi.encode(first)
        );
        vm.expectEmit(true, true, false, true);
        emit ICapabilitiesRegistry.WhitelistCapability(adapter, capability, second);
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, capability, second);
        assertEq(
            abi.encode(ICapabilitiesRegistry(registry).getCapabilitySelectors(adapter, capability)), abi.encode(second)
        );
    }

    function test_EmptyListUnwhitelistsAndCanBeReplaced() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("borrow(uint256)"));
        vm.startPrank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, capability, selectors);
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, capability, new bytes4[](0));
        assertEq(ICapabilitiesRegistry(registry).getCapabilitySelectors(adapter, capability).length, 0);
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, capability, selectors);
        assertEq(
            abi.encode(ICapabilitiesRegistry(registry).getCapabilitySelectors(adapter, capability)),
            abi.encode(selectors)
        );
    }

    function test_WhitelistIsScopedToAdapterAndCapability() public {
        address otherAdapter = makeAddr("otherAdapter");
        address otherCapability = address(new RegistryCapabilityMock());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("borrow(uint256)"));
        vm.prank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, capability, selectors);
        assertEq(ICapabilitiesRegistry(registry).getCapabilitySelectors(otherAdapter, capability).length, 0);
        assertEq(ICapabilitiesRegistry(registry).getCapabilitySelectors(adapter, otherCapability).length, 0);
        vm.prank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(otherAdapter, capability, selectors);
        vm.prank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, capability, new bytes4[](0));
        assertEq(
            abi.encode(ICapabilitiesRegistry(registry).getCapabilitySelectors(otherAdapter, capability)),
            abi.encode(selectors)
        );
    }

    function test_OnlyOwnerCanWhitelistOrUnwhitelist(address caller, bytes4[] memory selectors) public {
        vm.assume(caller != owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, capability, selectors);
    }

    function test_RejectsNonContractButRevocationRemainsAvailable(address nonContract) public {
        vm.assume(nonContract.code.length == 0);
        vm.startPrank(owner);
        vm.expectRevert(ICapabilitiesRegistry.InvalidCapabilityCode.selector);
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, nonContract, new bytes4[](1));
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, nonContract, new bytes4[](0));
        assertEq(ICapabilitiesRegistry(registry).getCapabilitySelectors(adapter, nonContract).length, 0);
    }

    function test_RevocationDoesNotRequireCapabilityCode() public {
        vm.startPrank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, capability, new bytes4[](1));
        vm.etch(capability, hex"");
        ICapabilitiesRegistry(registry).whitelistCapability(adapter, capability, new bytes4[](0));
        assertEq(ICapabilitiesRegistry(registry).getCapabilitySelectors(adapter, capability).length, 0);
    }
}
