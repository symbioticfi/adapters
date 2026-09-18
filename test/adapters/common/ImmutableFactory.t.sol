// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {BorrowCapability} from "src/contracts/merkle_adapter/BorrowCapability.sol";
import {Executor} from "src/contracts/periphery/Executor.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";

import {IBorrowCapability} from "src/interfaces/merkle_adapter/IBorrowCapability.sol";
import {ICapability} from "src/interfaces/merkle_adapter/ICapability.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";

import {Test} from "forge-std/Test.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/BorrowCapabilityMocks.sol";

contract ImmutableFactoryTest is Test {
    function test_DeploysExecutorWithExplicitOwnerAndAdapter() public {
        address factory = address(new ImmutableFactory(type(Executor).creationCode));
        address owner = makeAddr("owner");
        address adapter = makeAddr("adapter");
        address creator = makeAddr("creator");
        vm.prank(creator);
        address executor = IImmutableFactory(factory).create(abi.encode(owner, adapter));

        assertTrue(IImmutableFactory(factory).isEntity(executor), "deployment must be registered");
        assertEq(IImmutableFactory(factory).totalEntities(), 1);
        assertEq(IImmutableFactory(factory).entity(0), executor);
        assertEq(Executor(executor).adapter(), adapter);
        assertEq(Executor(executor).owner(), owner);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        Executor(executor).setCaller(creator);
        vm.prank(owner);
        Executor(executor).setCaller(creator);
        assertEq(Executor(executor).caller(), creator);
    }

    function test_DeploysSharedBorrowCapabilityWithoutConstructorArguments() public {
        address factory = address(new ImmutableFactory(type(BorrowCapability).creationCode));
        address capability = IImmutableFactory(factory).create("");
        assertTrue(IImmutableFactory(factory).isEntity(capability));
        BorrowTestCall memory healthFactor = BorrowTestCall(address(1), hex"12345678");
        assertEq(
            BorrowCapability(capability).minHealthFactor(keccak256(abi.encode(healthFactor.target, healthFactor.data))),
            0
        );
        vm.expectRevert(ICapability.InvalidCaller.selector);
        BorrowCapability(capability)
            .borrow(healthFactor.target, healthFactor.target, healthFactor.data, healthFactor.data);
    }

    function testFuzz_AppendsStaticAndDynamicConstructorArguments(address owner, uint256 value, bytes memory payload)
        public
    {
        address factory = address(new ImmutableFactory(type(ImmutableFactoryFixture).creationCode));
        address deployed = IImmutableFactory(factory).create(abi.encode(owner, value, payload));
        assertEq(ImmutableFactoryFixture(deployed).owner(), owner);
        assertEq(ImmutableFactoryFixture(deployed).value(), value);
        assertEq(ImmutableFactoryFixture(deployed).payload(), payload);
        assertEq(ImmutableFactoryFixture(deployed).creator(), factory);
        assertEq(deployed.code, address(new ImmutableFactoryFixture(owner, value, payload)).code);
        assertTrue(IImmutableFactory(factory).isEntity(deployed));
    }

    function test_RepeatedArgumentsCreateDistinctRegisteredInstances() public {
        address factory = address(new ImmutableFactory(type(ImmutableFactoryFixture).creationCode));
        bytes memory data = abi.encode(address(this), uint256(42), hex"123456");
        address first = IImmutableFactory(factory).create(data);
        address second = IImmutableFactory(factory).create(data);
        assertNotEq(first, second);
        assertEq(first.code, second.code);
        assertEq(IImmutableFactory(factory).totalEntities(), 2);
        assertEq(IImmutableFactory(factory).entity(0), first);
        assertEq(IImmutableFactory(factory).entity(1), second);
        assertTrue(IImmutableFactory(factory).isEntity(first));
        assertTrue(IImmutableFactory(factory).isEntity(second));
        assertEq(IImmutableFactory(factory).implementation(), type(ImmutableFactoryFixture).creationCode);
    }

    function test_EmitsRegistryEventAfterSuccessfulDeployment() public {
        address factory = address(new ImmutableFactory(type(BorrowCapability).creationCode));
        address predicted = vm.computeCreateAddress(factory, vm.getNonce(factory));
        vm.expectEmit(factory);
        emit IRegistry.AddEntity(predicted);
        assertEq(IImmutableFactory(factory).create(""), predicted);
        assertTrue(IImmutableFactory(factory).isEntity(predicted));
    }

    function test_UsesFixedBytecodeAndKeepsFactoryRegistriesIndependent() public {
        address borrowFactory = address(new ImmutableFactory(type(BorrowCapability).creationCode));
        address executorFactory = address(new ImmutableFactory(type(Executor).creationCode));
        address capability = IImmutableFactory(borrowFactory).create("");
        address executor = IImmutableFactory(executorFactory).create(abi.encode(address(this), address(1)));
        assertFalse(IImmutableFactory(borrowFactory).isEntity(executor));
        assertFalse(IImmutableFactory(executorFactory).isEntity(capability));
        assertEq(IImmutableFactory(borrowFactory).implementation(), type(BorrowCapability).creationCode);
        assertEq(IImmutableFactory(executorFactory).implementation(), type(Executor).creationCode);
    }

    function test_ConstructorRevertLeavesRegistryAndNonceUnchanged() public {
        address factory = address(new ImmutableFactory(type(Executor).creationCode));
        uint64 nonce = vm.getNonce(factory);
        address predicted = vm.computeCreateAddress(factory, nonce);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        IImmutableFactory(factory).create(abi.encode(address(0), address(1)));
        assertEq(IImmutableFactory(factory).totalEntities(), 0);
        assertFalse(IImmutableFactory(factory).isEntity(predicted));
        assertEq(predicted.code.length, 0);
        assertEq(vm.getNonce(factory), nonce);
        assertEq(IImmutableFactory(factory).create(abi.encode(address(this), address(1))), predicted);
    }

    function testFuzz_BubblesCompleteConstructorRevertData(bytes memory reason) public {
        vm.assume(reason.length > 0);
        address factory = address(new ImmutableFactory(type(ImmutableFactoryRevertingFixture).creationCode));
        vm.expectRevert(reason);
        IImmutableFactory(factory).create(abi.encode(reason));
        assertEq(IImmutableFactory(factory).totalEntities(), 0);
    }

    function test_EmptyConstructorRevertUsesDeploymentFailed() public {
        address factory = address(new ImmutableFactory(type(ImmutableFactoryRevertingFixture).creationCode));
        vm.expectRevert(IImmutableFactory.DeploymentFailed.selector);
        IImmutableFactory(factory).create(abi.encode(bytes("")));
        assertEq(IImmutableFactory(factory).totalEntities(), 0);
    }

    function test_MalformedArgumentsDoNotRegisterAnEntity() public {
        address factory = address(new ImmutableFactory(type(Executor).creationCode));
        vm.expectRevert(IImmutableFactory.DeploymentFailed.selector);
        IImmutableFactory(factory).create(hex"1234");
        assertEq(IImmutableFactory(factory).totalEntities(), 0);
    }

    function testFuzz_FailedOrEmptyCodeDeploymentIsNotRegistered(uint8 kind) public {
        kind = uint8(bound(kind, 0, 2));
        address factory =
            address(new ImmutableFactory(kind == 0 ? bytes("") : kind == 1 ? bytes(hex"00") : bytes(hex"fe")));
        uint64 nonce = vm.getNonce(factory);
        address predicted = vm.computeCreateAddress(factory, nonce);
        vm.expectRevert(IImmutableFactory.DeploymentFailed.selector);
        IImmutableFactory(factory).create{gas: 500_000}("");
        assertEq(IImmutableFactory(factory).totalEntities(), 0);
        assertEq(vm.getNonce(factory), nonce);
        assertEq(predicted.code.length, 0);
    }
}

contract ImmutableFactoryFixture {
    address public immutable owner;
    uint256 public immutable value;
    address public creator;
    bytes public payload;

    constructor(address newOwner, uint256 newValue, bytes memory newPayload) {
        owner = newOwner;
        value = newValue;
        creator = msg.sender;
        payload = newPayload;
    }
}

contract ImmutableFactoryRevertingFixture {
    constructor(bytes memory reason) {
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }
}
