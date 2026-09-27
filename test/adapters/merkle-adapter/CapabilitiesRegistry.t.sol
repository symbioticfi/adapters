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

    /// forge-config: default.isolate = true
    function test_EmptyListUnwhitelistsAndCanBeReplaced() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("borrow(uint256)"));
        vm.startPrank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, selectors);
        vm.snapshotGasLastCall("CapabilitiesRegistry", "whitelistCapabilityNew");
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, new bytes4[](0));
        vm.snapshotGasLastCall("CapabilitiesRegistry", "whitelistCapabilityClear");
        _assertSelectors(account, capability, new bytes4[](0));
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, selectors);
        vm.snapshotGasLastCall("CapabilitiesRegistry", "whitelistCapabilityRestore");
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

    function test_WhitelistAndRevokeWithoutCapabilityCode(address nonContract) public {
        vm.assume(nonContract.code.length == 0);
        vm.startPrank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(account, nonContract, new bytes4[](1));
        _assertSelectors(account, nonContract, new bytes4[](1));
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

    /// forge-config: default.isolate = true
    function test_GasSelectorReadsAndReplacement() public {
        bytes4[] memory actual = ICapabilitiesRegistry(registry).selectors(account, capability);
        vm.snapshotGasLastCall("CapabilitiesRegistry", "selectorsEmpty");
        assertEq(actual.length, 0);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("borrow(uint256)"));
        selectors[1] = bytes4(keccak256("repay(uint256)"));
        vm.prank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, selectors);
        actual = ICapabilitiesRegistry(registry).selectors(account, capability);
        vm.snapshotGasLastCall("CapabilitiesRegistry", "selectorsConfigured");
        assertEq(actual.length, 2);
        assertEq(actual[0], selectors[0]);
        assertEq(actual[1], selectors[1]);

        selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("withdraw(uint256)"));
        vm.prank(owner);
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, selectors);
        vm.snapshotGasLastCall("CapabilitiesRegistry", "whitelistCapabilityReplace");
        _assertSelectors(account, capability, selectors);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        vm.prank(account);
        vm.startSnapshotGas("CapabilitiesRegistry", "whitelistCapabilityUnauthorizedRegion");
        ICapabilitiesRegistry(registry).whitelistCapability(account, capability, new bytes4[](0));
        vm.stopSnapshotGas();
        _assertSelectors(account, capability, selectors);
    }

    function _assertSelectors(address target, address implementation, bytes4[] memory expected) internal view {
        bytes4[] memory actual = ICapabilitiesRegistry(registry).selectors(target, implementation);
        assertEq(actual.length, expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(actual[i], expected[i]);
        }
    }
}
