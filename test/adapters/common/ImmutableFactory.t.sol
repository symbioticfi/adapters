// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";

import {Test} from "forge-std/Test.sol";

import {SSTORE2} from "solady/utils/SSTORE2.sol";

contract ImmutableFactoryTest is Test {
    function test_DeploysExecutorWithExplicitOwnerAndAccount() public {
        address factory = address(new ImmutableFactory(type(RecipeExecutor).creationCode));
        address owner = makeAddr("owner");
        address account = makeAddr("account");
        address creator = makeAddr("creator");
        vm.prank(creator);
        address executor = IImmutableFactory(factory).create(abi.encode(owner, account));

        assertTrue(IImmutableFactory(factory).isEntity(executor), "deployment must be registered");
        assertEq(IImmutableFactory(factory).totalEntities(), 1);
        assertEq(IImmutableFactory(factory).entity(0), executor);
        assertEq(RecipeExecutor(executor).account(), account);
        assertEq(RecipeExecutor(executor).owner(), owner);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        RecipeExecutor(executor).setCaller(creator);
        vm.prank(owner);
        RecipeExecutor(executor).setCaller(creator);
        assertEq(RecipeExecutor(executor).caller(), creator);
    }

    function test_DeploysSharedGuardedCallsCapabilityWithoutConstructorArguments() public {
        address factory = address(new ImmutableFactory(type(GuardedCallsCapability).creationCode));
        address capability = IImmutableFactory(factory).create("");
        assertTrue(IImmutableFactory(factory).isEntity(capability));
        vm.expectRevert(IGuardedCallsCapability.InvalidCaller.selector);
        GuardedCallsCapability(capability)
            .execute(new IGuardedCallsCapability.Call[](0), new IGuardedCallsCapability.Check[](0));
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
        assertEq(
            SSTORE2.read(IImmutableFactory(factory).implementationPointer()), type(ImmutableFactoryFixture).creationCode
        );
    }

    function test_EmitsRegistryEventAfterSuccessfulDeployment() public {
        address factory = address(new ImmutableFactory(type(GuardedCallsCapability).creationCode));
        address predicted = vm.computeCreateAddress(factory, vm.getNonce(factory));
        vm.expectEmit(factory);
        emit IRegistry.AddEntity(predicted);
        assertEq(IImmutableFactory(factory).create(""), predicted);
        assertTrue(IImmutableFactory(factory).isEntity(predicted));
    }

    function test_UsesFixedBytecodeAndKeepsFactoryRegistriesIndependent() public {
        address borrowFactory = address(new ImmutableFactory(type(GuardedCallsCapability).creationCode));
        address executorFactory = address(new ImmutableFactory(type(RecipeExecutor).creationCode));
        address capability = IImmutableFactory(borrowFactory).create("");
        address executor = IImmutableFactory(executorFactory).create(abi.encode(address(this), address(1)));
        assertFalse(IImmutableFactory(borrowFactory).isEntity(executor));
        assertFalse(IImmutableFactory(executorFactory).isEntity(capability));
        assertEq(
            SSTORE2.read(IImmutableFactory(borrowFactory).implementationPointer()),
            type(GuardedCallsCapability).creationCode
        );
        assertEq(
            SSTORE2.read(IImmutableFactory(executorFactory).implementationPointer()), type(RecipeExecutor).creationCode
        );
    }

    function test_ConstructorRevertLeavesRegistryAndNonceUnchanged() public {
        address factory = address(new ImmutableFactory(type(RecipeExecutor).creationCode));
        uint64 nonce = vm.getNonce(factory);
        address predicted = vm.computeCreateAddress(factory, nonce);
        vm.expectRevert(IImmutableFactory.DeploymentFailed.selector);
        IImmutableFactory(factory).create(abi.encode(address(0), address(1)));
        assertEq(IImmutableFactory(factory).totalEntities(), 0);
        assertFalse(IImmutableFactory(factory).isEntity(predicted));
        assertEq(predicted.code.length, 0);
        assertEq(vm.getNonce(factory), nonce);
        assertEq(IImmutableFactory(factory).create(abi.encode(address(this), address(1))), predicted);
    }

    function testFuzz_ConstructorRevertUsesDeploymentFailed(bytes memory reason) public {
        vm.assume(reason.length > 0);
        address factory = address(new ImmutableFactory(type(ImmutableFactoryRevertingFixture).creationCode));
        vm.expectRevert(IImmutableFactory.DeploymentFailed.selector);
        IImmutableFactory(factory).create(abi.encode(reason));
        assertEq(IImmutableFactory(factory).totalEntities(), 0);
    }

    function test_LargeConstructorRevertUsesDeploymentFailed() public {
        bytes memory reason = new bytes(32_768);
        reason[0] = 0x12;
        reason[16_384] = 0xab;
        reason[32_767] = 0xef;
        address factory = address(new ImmutableFactory(type(ImmutableFactoryRevertingFixture).creationCode));
        uint64 nonce = vm.getNonce(factory);
        vm.expectRevert(IImmutableFactory.DeploymentFailed.selector);
        IImmutableFactory(factory).create(abi.encode(reason));
        assertEq(IImmutableFactory(factory).totalEntities(), 0);
        assertEq(vm.getNonce(factory), nonce);
    }

    function test_EmptyImplementationAcceptsCompleteCreationCodeAsArguments() public {
        address factory = address(new ImmutableFactory(""));
        address deployed = IImmutableFactory(factory)
            .create(bytes.concat(type(ImmutableFactoryFixture).creationCode, abi.encode(address(this), 42, hex"1234")));
        assertEq(ImmutableFactoryFixture(deployed).owner(), address(this));
        assertEq(ImmutableFactoryFixture(deployed).value(), 42);
        assertEq(ImmutableFactoryFixture(deployed).payload(), hex"1234");
        assertEq(ImmutableFactoryFixture(deployed).creator(), factory);
        assertTrue(IImmutableFactory(factory).isEntity(deployed));
        assertEq(SSTORE2.read(IImmutableFactory(factory).implementationPointer()), "");
    }

    function test_EmptyConstructorRevertUsesDeploymentFailed() public {
        address factory = address(new ImmutableFactory(type(ImmutableFactoryRevertingFixture).creationCode));
        vm.expectRevert(IImmutableFactory.DeploymentFailed.selector);
        IImmutableFactory(factory).create(abi.encode(bytes("")));
        assertEq(IImmutableFactory(factory).totalEntities(), 0);
    }

    function test_MalformedArgumentsDoNotRegisterAnEntity() public {
        address factory = address(new ImmutableFactory(type(RecipeExecutor).creationCode));
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

contract ImmutableFactoryCodeSizeTest is Test {
    function test_DeploysUpToCodeStorageLimit() public {
        uint256[2] memory lengths = [uint256(24_574), 24_575];
        bytes memory runtime = abi.encode(bytes32(hex"602a60005260206000f3"));
        for (uint256 i; i < lengths.length; ++i) {
            // Copy the appended 32-byte constructor argument into runtime code, ignoring padding.
            bytes memory bytecode = bytes.concat(
                hex"602061", bytes2(uint16(lengths[i])), hex"60003960206000f3", new bytes(lengths[i] - 13)
            );
            address factory = address(new ImmutableFactory(bytecode));
            address predicted = vm.computeCreateAddress(factory, vm.getNonce(factory));
            address deployed = IImmutableFactory(factory).create(runtime);
            assertEq(deployed, predicted);
            assertEq(deployed.code, runtime);
            assertEq(SSTORE2.read(IImmutableFactory(factory).implementationPointer()), bytecode);
            assertEq(IImmutableFactory(factory).entity(0), deployed);
            assertEq(IImmutableFactory(factory).totalEntities(), 1);
            assertTrue(IImmutableFactory(factory).isEntity(deployed));
            (bool success, bytes memory result) = deployed.staticcall("");
            assertTrue(success);
            assertEq(abi.decode(result, (uint256)), 42);
        }
    }

    function test_RejectsCreationBytecodeAboveCodeStorageLimit() public {
        // Forge otherwise lifts the EVM code-size limit for tests. CI runs this suite with it enabled.
        vm.skip(vm.envOr("FOUNDRY_CODE_SIZE_LIMIT", uint256(0)) != 24_576);
        vm.expectRevert(IImmutableFactory.DeploymentFailed.selector);
        new ImmutableFactory(new bytes(24_576));
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
