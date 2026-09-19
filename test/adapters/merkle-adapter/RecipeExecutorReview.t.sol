// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {RecipeExecutor} from "../../../src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {IRecipeExecutor} from "../../../src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Test} from "forge-std/Test.sol";

contract RecipeReviewTarget {
    uint256 public recorded;
    address public caller;

    function record(uint256 amount) public {
        recorded = amount;
        caller = msg.sender;
    }

    function raw(bytes memory data) public pure {
        assembly ("memory-safe") {
            return(add(data, 32), mload(data))
        }
    }
}

contract RecipeReviewOwner {
    address public executor;
    bool public checked;

    function configure(address newExecutor, address newCaller, IRecipeExecutor.Step[] calldata recipe) public {
        executor = newExecutor;
        RecipeExecutor(executor).setCaller(newCaller);
        RecipeExecutor(executor).setRecipe(recipe);
    }

    function probe() public {
        require(executor == msg.sender);
        IRecipeExecutor.Step[] memory empty = new IRecipeExecutor.Step[](0);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(RecipeExecutor.setRecipe, (empty));
        calls[1] = abi.encodeCall(RecipeExecutor.setCaller, (address(0)));
        calls[2] = abi.encodeCall(RecipeExecutor.execute, (new uint256[](0), new bytes[](0)));
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory result) = executor.call(calls[i]);
            require(!success);
            require(bytes4(result) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        }
        checked = true;
    }
}

contract RecipeExecutorReviewTest is Test {
    RecipeExecutor internal executor;
    RecipeReviewTarget internal target;

    function setUp() public {
        executor = new RecipeExecutor(address(this), address(1));
        executor.setCaller(address(this));
        target = new RecipeReviewTarget();
    }

    function testFuzz_StorageCopiesEveryStepField(uint8 operation, uint256 a, uint256 b, uint256 c, bytes memory data)
        public
    {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation(operation % 13), a, b, c, data);
        executor.setRecipe(recipe);
        (
            IRecipeExecutor.Operation storedOperation,
            uint256 storedA,
            uint256 storedB,
            uint256 storedC,
            bytes memory storedData
        ) = executor.steps(0);
        assertEq(uint256(storedOperation), uint256(recipe[0].operation));
        assertEq(storedA, a);
        assertEq(storedB, b);
        assertEq(storedC, c);
        assertEq(storedData, data);
    }

    function testFuzz_StaticArgumentBindingRejectsChangedAmount(uint256 amount) public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](4);
        recipe[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, amount, 0, 0, "");
        recipe[1] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Calldata, 3, 4, 0, "");
        recipe[2] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Equal, 0, 1, 0, "");
        recipe[3] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Invoke, 0, 0, 0, abi.encode(address(target), RecipeReviewTarget.record.selector)
        );
        executor.setRecipe(recipe);
        bytes[] memory runtime = new bytes[](4);
        runtime[3] = abi.encodeCall(RecipeReviewTarget.record, (amount));
        executor.execute(new uint256[](0), runtime);
        assertEq(target.recorded(), amount);
        assertEq(target.caller(), address(executor));

        runtime[3] = abi.encodeCall(RecipeReviewTarget.record, (amount ^ 1));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        executor.execute(new uint256[](0), runtime);
        assertEq(target.recorded(), amount);
    }

    function testFuzz_WordReadsMatchBytes(bytes memory data, bytes32 tail, uint256 offset) public {
        data = bytes.concat(data, tail);
        _assertWordReads(data, bound(offset, 0, data.length - 32));
        _assertWordReads(data, data.length - 32);
    }

    function test_WordReadsRequireCompleteWords() public {
        for (uint256 length; length <= 33; ++length) {
            _assertWordReads(new bytes(length), 0);
        }
        _assertWordReads(new bytes(33), 1);
        for (uint256 remaining; remaining < 32; ++remaining) {
            _assertWordReads(new bytes(64), 64 - remaining);
        }
        _assertWordReads(new bytes(64), 65);
        _assertWordReads(new bytes(64), type(uint256).max);
    }

    function test_PostconditionFailureRollsBackInvokedState() public {
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](4);
        recipe[0] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, 1, 0, 0, "");
        recipe[1] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Invoke, 0, 0, 0, abi.encode(address(target), RecipeReviewTarget.record.selector)
        );
        recipe[2] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Read, 0, 0, 0, abi.encode(address(target), abi.encodeWithSignature("recorded()"))
        );
        recipe[3] = IRecipeExecutor.Step(IRecipeExecutor.Operation.Equal, 0, 2, 0, "");
        executor.setRecipe(recipe);
        bytes[] memory runtime = new bytes[](4);
        runtime[1] = abi.encodeCall(RecipeReviewTarget.record, (2));

        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        executor.execute(new uint256[](0), runtime);
        assertEq(target.recorded(), 0);
        assertEq(target.caller(), address(0));
    }

    function test_OwnerCallbackCannotChangeConfigurationOrReenter() public {
        RecipeReviewOwner owner = new RecipeReviewOwner();
        executor = new RecipeExecutor(address(owner), address(1));
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        recipe[0] = IRecipeExecutor.Step(
            IRecipeExecutor.Operation.Invoke, 0, 0, 0, abi.encode(address(owner), RecipeReviewOwner.probe.selector)
        );
        owner.configure(address(executor), address(this), recipe);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encodeCall(RecipeReviewOwner.probe, ());
        executor.execute(new uint256[](0), runtime);

        assertTrue(owner.checked());
        (IRecipeExecutor.Operation operation, uint256 a, uint256 b, uint256 c, bytes memory data) = executor.steps(0);
        assertEq(uint256(operation), uint256(recipe[0].operation));
        assertEq(a, recipe[0].a);
        assertEq(b, recipe[0].b);
        assertEq(c, recipe[0].c);
        assertEq(data, recipe[0].data);
        assertEq(executor.caller(), address(this));
    }

    function _assertWordReads(bytes memory data, uint256 offset) internal {
        bool valid = data.length >= 32 && offset <= data.length - 32;
        uint256 expected;
        if (valid) {
            for (uint256 i; i < 32; ++i) {
                expected = (expected << 8) | uint8(data[offset + i]);
            }
        }
        IRecipeExecutor.Step[] memory recipe = new IRecipeExecutor.Step[](1);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = data;
        for (uint256 i; i < 2; ++i) {
            recipe[0] = IRecipeExecutor.Step(
                i == 0 ? IRecipeExecutor.Operation.Read : IRecipeExecutor.Operation.Calldata,
                i == 0 ? offset : 0,
                i == 0 ? 0 : offset,
                0,
                abi.encode(address(target), abi.encodeCall(RecipeReviewTarget.raw, (data)))
            );
            executor.setRecipe(recipe);
            if (!valid) vm.expectRevert();
            uint256[] memory values = executor.execute(new uint256[](0), runtime);
            if (valid) assertEq(values[0], expected);
        }
    }
}
