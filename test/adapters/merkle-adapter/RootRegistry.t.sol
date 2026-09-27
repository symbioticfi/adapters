// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Test} from "forge-std/Test.sol";

contract RootRegistryTest is Test {
    address internal _registry;
    address internal _account = makeAddr("account");

    function setUp() public {
        _registry = address(new RootRegistry(address(this)));
    }

    /// forge-config: default.isolate = true
    function test_GasRootPublicationReplacementAndClear() public {
        bytes32 first = keccak256("first root");
        bytes32 second = keccak256("second root");
        RootRegistry(_registry).setRoot(_account, first);
        vm.snapshotGasLastCall("RootRegistry", "setRootNew");
        assertEq(RootRegistry(_registry).roots(_account), first);
        RootRegistry(_registry).setRoot(_account, second);
        vm.snapshotGasLastCall("RootRegistry", "setRootReplace");
        assertEq(RootRegistry(_registry).roots(_account), second);
        RootRegistry(_registry).setRoot(_account, bytes32(0));
        vm.snapshotGasLastCall("RootRegistry", "setRootClear");
        assertEq(RootRegistry(_registry).roots(_account), bytes32(0));
    }

    /// forge-config: default.isolate = true
    function test_GasRootPublicationRejectsNonOwner() public {
        address caller = makeAddr("caller");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        vm.startSnapshotGas("RootRegistry", "setRootUnauthorizedRegion");
        RootRegistry(_registry).setRoot(_account, keccak256("unauthorized root"));
        vm.stopSnapshotGas();
        assertEq(RootRegistry(_registry).roots(_account), bytes32(0));
    }
}
