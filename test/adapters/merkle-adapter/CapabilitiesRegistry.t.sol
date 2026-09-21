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
    address internal account = makeAddr("account");

    function setUp() public {
        registry = address(new CapabilitiesRegistry(owner));
        capability = address(new RegistryCapabilityMock());
    }

    function test_WhitelistReplacesSelectors(bytes4[] memory first, bytes4[] memory second) public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit ICapabilitiesRegistry.WhitelistCapability(account, capability, first);
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, first);
        _assertSelectors(account, capability, first);
        vm.expectEmit(true, true, false, true);
        emit ICapabilitiesRegistry.WhitelistCapability(account, capability, second);
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, second);
        _assertSelectors(account, capability, second);
    }

    function test_EmptyListUnwhitelistsAndCanBeReplaced() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("borrow(uint256)"));
        vm.startPrank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, selectors);
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, new bytes4[](0));
        _assertSelectors(account, capability, new bytes4[](0));
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, selectors);
        _assertSelectors(account, capability, selectors);
    }

    function test_WhitelistIsScopedToAccountAndCapability() public {
        address otherAccount = makeAddr("otherAccount");
        address otherCapability = address(new RegistryCapabilityMock());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("borrow(uint256)"));
        vm.prank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, selectors);
        _assertSelectors(otherAccount, capability, new bytes4[](0));
        _assertSelectors(account, otherCapability, new bytes4[](0));
        vm.prank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(otherAccount, capability, selectors);
        vm.prank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, new bytes4[](0));
        _assertSelectors(otherAccount, capability, selectors);
    }

    function test_OnlyOwnerCanWhitelistOrUnwhitelist(address caller, bytes4[] memory selectors) public {
        vm.assume(caller != owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, selectors);
    }

    function test_RejectsNonContractButRevocationRemainsAvailable(address nonContract) public {
        vm.assume(nonContract.code.length == 0);
        vm.startPrank(owner);
        vm.expectRevert(ICapabilitiesRegistry.InvalidCapabilityCode.selector);
        ICapabilitiesRegistry(registry).whitelistCapability(account, nonContract, new bytes4[](1));
        ICapabilitiesRegistry(registry).whitelistCapability(account, nonContract, new bytes4[](0));
        _assertSelectors(account, nonContract, new bytes4[](0));
    }

    function test_RevocationDoesNotRequireCapabilityCode() public {
        vm.startPrank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, new bytes4[](1));
        vm.etch(capability, hex"");
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, new bytes4[](0));
        _assertSelectors(account, capability, new bytes4[](0));
    }

    function _assertSelectors(address target, address implementation, bytes4[] memory expected) internal {
        assertEq(ICapabilitiesRegistry(registry).capabilitySelectorsLength(target, implementation), expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(ICapabilitiesRegistry(registry).capabilitySelectors(target, implementation, i), expected[i]);
        }
        vm.expectRevert();
        ICapabilitiesRegistry(registry).capabilitySelectors(target, implementation, expected.length);
    }
}
