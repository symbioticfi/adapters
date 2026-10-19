// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {Token} from "test/mocks/Token.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {
    IRecipes,
    OP_ADD,
    OP_CALL,
    OP_EQUAL,
    OP_READ,
    OP_READ_CACHED,
    OP_READ_IF,
    OP_READ_WORD,
    SRC_INPUT,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {stdError} from "forge-std/StdError.sol";

contract RecipeTupleTest is CapabilityTestBase {
    address internal _executor;
    uint256 public first = 7;
    uint256 public second = 11;

    function setUp() public {
        _deployAdapter(address(new Token("Recipe tuple")));
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
    }

    function testFuzz_CachedWordsRetainAllBitsAcrossBindingsAndContexts(bool capability, uint256 a, uint256 b) public {
        uint256[] memory bindings = new uint256[](2);
        bindings[0] = (uint256(4) << 224) | _input(0);
        bindings[1] = (uint256(36) << 224) | _input(1);
        bytes[] memory queries = new bytes[](2);
        queries[0] =
            abi.encode(address(this), abi.encodeCall(this.tuple, (uint256(0), uint256(0))), bindings, uint256(0));
        bindings = new uint256[](1);
        bindings[0] = (uint256(4) << 224) | _result(1);
        queries[1] = abi.encode(address(this), abi.encodeCall(this.echo, (uint256(0))), bindings, uint256(0));
        bytes[] memory steps = new bytes[](5);
        steps[0] = _cached(0);
        steps[1] = _word(0, 32);
        steps[2] = abi.encodePacked(OP_READ, abi.encode(uint256(1)));
        steps[3] = abi.encodePacked(
            OP_CALL, abi.encode(address(this), abi.encodeCall(this.setSecond, (uint256(0))), bindings)
        );
        steps[4] = abi.encodePacked(OP_ADD, abi.encode(_result(0), uint256(0)));
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = a;
        inputs[1] = b;
        uint256[] memory values = capability ? _runCapability(queries, steps, inputs) : _run(queries, steps, inputs);
        assertEq(values[0], a);
        assertEq(values[1], b);
        assertEq(values[2], b);
        assertEq(values[4], a);
        assertEq(second, b);
    }

    function test_MaxWordsRemainFullWidth() public {
        testFuzz_CachedWordsRetainAllBitsAcrossBindingsAndContexts(false, type(uint256).max, type(uint256).max);
        testFuzz_CachedWordsRetainAllBitsAcrossBindingsAndContexts(true, type(uint256).max, type(uint256).max);
    }

    function test_CachedReadUsesQueryOffsetAndRetainsEarlierWords() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 32);
        bytes[] memory steps = new bytes[](2);
        steps[0] = _cached(0);
        steps[1] = _word(0, 0);
        uint256[] memory values = _run(queries, steps, new uint256[](0));
        assertEq(values[0], second);
        assertEq(values[1], first);
    }

    function testFuzz_CachedWordsAllowUnalignedOffsets(uint256 a, uint256 b, uint8 offset) public {
        offset = uint8(bound(offset, 0, 32));
        bytes memory data = abi.encode(a, b);
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.raw, (data)), 0);
        bytes[] memory steps = new bytes[](2);
        steps[0] = _cached(0);
        steps[1] = _word(0, offset);
        uint256 expected;
        assembly ("memory-safe") {
            expected := mload(add(add(data, 32), offset))
        }
        assertEq(_run(queries, steps, new uint256[](0))[1], expected);
    }

    function test_CachedReadRunsOnlyOneGetter() public {
        bytes[] memory queries = new bytes[](1);
        bytes memory data = abi.encodeCall(this.storedTuple, ());
        queries[0] = _query(data, 0);
        bytes[] memory steps = new bytes[](3);
        steps[0] = _cached(0);
        steps[1] = _word(0, 32);
        steps[2] = _word(0, 0);
        vm.expectCall(address(this), data, uint64(1));
        uint256[] memory values = _run(queries, steps, new uint256[](0));
        assertEq(values[0], first);
        assertEq(values[1], second);
        assertEq(values[2], first);
    }

    function test_OrdinaryAndConditionalReadsKeepTheirFreshAndLazySemantics() public {
        bytes[] memory queries = new bytes[](2);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 0);
        queries[1] = _query(abi.encodeCall(this.storedTuple, ()), 32);
        bytes[] memory steps = new bytes[](6);
        steps[0] = _cached(0);
        steps[1] = abi.encodePacked(
            OP_CALL, abi.encode(address(this), abi.encodeCall(this.setSecond, (uint256(13))), new uint256[](0))
        );
        steps[2] = abi.encodePacked(OP_READ, abi.encode(uint256(1)));
        steps[3] = abi.encodePacked(OP_READ_IF, abi.encode(uint256(1), uint256(1), _result(5)));
        steps[4] = abi.encodePacked(OP_READ_IF, abi.encode(uint256(0), type(uint256).max, _result(2)));
        steps[5] = _word(0, 32);
        uint256[] memory values = _run(queries, steps, new uint256[](0));
        assertEq(values[2], 13);
        assertEq(values[3], 13);
        assertEq(values[4], 13);
        assertEq(values[5], 11);
    }

    function test_FreshCachedReadObservesActionAndPreservesExtractedResults() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 0);
        bytes[] memory steps = new bytes[](6);
        steps[0] = _cached(0);
        steps[1] = _word(0, 32);
        steps[2] = abi.encodePacked(
            OP_CALL, abi.encode(address(this), abi.encodeCall(this.setSecond, (uint256(13))), new uint256[](0))
        );
        steps[3] = _cached(0);
        steps[4] = _word(3, 32);
        steps[5] = abi.encodePacked(OP_ADD, abi.encode(_result(1), uint256(0)));
        uint256[] memory values = _run(queries, steps, new uint256[](0));
        assertEq(values[1], 11);
        assertEq(values[4], 13);
        assertEq(values[5], 11);
    }

    function test_RejectsSelfFutureMissingAndNonCachedProducers() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 0);
        bytes[] memory steps = new bytes[](2);
        for (uint256 index; index < 4; ++index) {
            steps[0] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
            steps[1] = _word(index == 3 ? type(uint256).max : index, 0);
            _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        }
        steps[0] = abi.encodePacked(OP_EQUAL, abi.encode(uint256(0), uint256(0)));
        steps[1] = _word(0, 0);
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        steps[0] = abi.encodePacked(OP_READ_IF, abi.encode(uint256(1), uint256(0), uint256(0)));
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        steps = new bytes[](1);
        steps[0] = _word(0, 0);
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
    }

    function test_RejectsReplacedCachedProducerAndWordProducer() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 0);
        bytes[] memory steps = new bytes[](3);
        steps[0] = _cached(0);
        steps[1] = _cached(0);
        steps[2] = _word(0, 32);
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        steps[1] = _word(0, 32);
        steps[2] = _word(1, 0);
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
    }

    function test_RejectsPackedProducerInsteadOfPlainInstructionIndex() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 0);
        bytes[] memory steps = new bytes[](2);
        steps[0] = _cached(0);
        steps[1] = _word(_result(0), 32);
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
    }

    function test_CacheDoesNotPersistAcrossExecutions() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 0);
        bytes[] memory steps = new bytes[](1);
        steps[0] = _cached(0);
        _run(queries, steps, new uint256[](0));
        steps = new bytes[](2);
        steps[0] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        steps[1] = _word(0, 32);
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
    }

    function testFuzz_RejectsIncompleteCachedWord(uint256 offset) public {
        offset = bound(offset, 33, type(uint256).max - 32);
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 0);
        bytes[] memory steps = new bytes[](2);
        steps[0] = _cached(0);
        steps[1] = _word(0, offset);
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidQuery.selector));
    }

    function test_CachedWordPreservesCheckedOffsetOverflow() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 0);
        bytes[] memory steps = new bytes[](2);
        steps[0] = _cached(0);
        for (uint256 offset = type(uint256).max - 31; offset < type(uint256).max; ++offset) {
            steps[1] = _word(0, offset);
            _expectRevert(queries, steps, stdError.arithmeticError);
        }
        steps[1] = _word(0, type(uint256).max);
        _expectRevert(queries, steps, stdError.arithmeticError);
    }

    function test_CachedReadValidatesBindingsQueryIndexAndReturnWord() public {
        bytes[] memory queries = new bytes[](1);
        bytes[] memory steps = new bytes[](1);
        steps[0] = _cached(1);
        _expectRevert(queries, steps, stdError.indexOOBError);
        steps[0] = _cached(0);
        queries[0] = hex"ff";
        _expectRevert(queries, steps, "");
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = (uint256(4) << 224) | _result(0);
        queries[0] = abi.encode(address(this), abi.encodeCall(this.echo, (uint256(0))), bindings, uint256(0));
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidReference.selector));
        queries[0] = _query(abi.encodeCall(this.raw, (new bytes(31))), 0);
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidQuery.selector));
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 33);
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidQuery.selector));
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), type(uint256).max);
        _expectRevert(queries, steps, stdError.arithmeticError);
    }

    function test_CachedReadBubblesTargetFailure() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.rejectRead, ()), 0);
        bytes[] memory steps = new bytes[](1);
        steps[0] = _cached(0);
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
    }

    function testFuzz_TruncatedCachedPayloadRejected(uint8 operation, uint8 length) public {
        operation = operation % 2 == 0 ? OP_READ_CACHED : OP_READ_WORD;
        length = uint8(bound(length, 0, operation == OP_READ_CACHED ? 31 : 63));
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(operation, new bytes(length));
        _expectRevert(new bytes[](0), steps, "");
    }

    function test_CapabilityRejectsExpiredCachedProducer() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 0);
        bytes[] memory steps = new bytes[](3);
        steps[0] = _cached(0);
        steps[1] = _cached(0);
        steps[2] = _word(0, 32);
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IRecipeCapability.execute, (queries, steps, new uint256[](0))));
        vm.expectRevert(IRecipes.InvalidReference.selector);
        MerkleAccount(payable(account)).manage(actions);
    }

    function test_FailedExtractionRollsBackPriorCall() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 0);
        bytes[] memory steps = new bytes[](3);
        steps[0] = _cached(0);
        steps[1] = abi.encodePacked(
            OP_CALL, abi.encode(address(this), abi.encodeCall(this.setSecond, (uint256(13))), new uint256[](0))
        );
        steps[2] = _word(0, 33);
        _expectRevert(queries, steps, abi.encodeWithSelector(IRecipes.InvalidQuery.selector));
        assertEq(second, 11);
    }

    /// forge-config: default.isolate = true
    function test_GasOrdinaryTupleReads() public {
        (bytes[] memory queries, bytes[] memory steps) = _tupleProgram(false);
        uint256[] memory values = _run(queries, steps, new uint256[](0));
        vm.snapshotGasLastCall("RecipeTuple", "ordinaryTupleReads");
        assertEq(values[0], first);
        assertEq(values[1], second);
    }

    /// forge-config: default.isolate = true
    function test_GasCachedTupleReads() public {
        (bytes[] memory queries, bytes[] memory steps) = _tupleProgram(true);
        uint256[] memory values = _run(queries, steps, new uint256[](0));
        vm.snapshotGasLastCall("RecipeTuple", "cachedTupleReads");
        assertEq(values[0], first);
        assertEq(values[1], second);
    }

    function setSecond(uint256 value) public {
        second = value;
    }

    function storedTuple() public view returns (uint256, uint256) {
        return (first, second);
    }

    function tuple(uint256 a, uint256 b) public pure returns (uint256, uint256) {
        return (a, b);
    }

    function echo(uint256 value) public pure returns (uint256) {
        return value;
    }

    function raw(bytes memory data) public pure {
        assembly ("memory-safe") {
            return(add(data, 32), mload(data))
        }
    }

    function rejectRead() public pure {
        revert IRecipes.CheckFailed();
    }

    function _expectRevert(bytes[] memory queries, bytes[] memory steps, bytes memory reason) internal {
        RecipeExecutor(_executor).setRecipe(queries, steps);
        if (reason.length > 0) vm.expectRevert(reason);
        else vm.expectRevert();
        RecipeExecutor(_executor).execute(queries, steps, new uint256[](0), new bytes[](0));
    }

    function _run(bytes[] memory queries, bytes[] memory steps, uint256[] memory inputs)
        internal
        returns (uint256[] memory)
    {
        RecipeExecutor(_executor).setRecipe(queries, steps);
        return RecipeExecutor(_executor).execute(queries, steps, inputs, new bytes[](0));
    }

    function _runCapability(bytes[] memory queries, bytes[] memory steps, uint256[] memory inputs)
        internal
        returns (uint256[] memory)
    {
        return abi.decode(
            _manage(account, abi.encodeCall(IRecipeCapability.execute, (queries, steps, inputs))), (uint256[])
        );
    }

    function _tupleProgram(bool cached) internal view returns (bytes[] memory queries, bytes[] memory steps) {
        queries = new bytes[](cached ? 1 : 2);
        queries[0] = _query(abi.encodeCall(this.storedTuple, ()), 0);
        if (!cached) queries[1] = _query(abi.encodeCall(this.storedTuple, ()), 32);
        steps = new bytes[](2);
        steps[0] = cached ? _cached(0) : abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        steps[1] = cached ? _word(0, 32) : abi.encodePacked(OP_READ, abi.encode(uint256(1)));
    }

    function _query(bytes memory data, uint256 offset) internal view returns (bytes memory) {
        return abi.encode(address(this), data, new uint256[](0), offset);
    }

    function _cached(uint256 queryIndex) internal pure returns (bytes memory) {
        return abi.encodePacked(OP_READ_CACHED, abi.encode(queryIndex));
    }

    function _word(uint256 producerIndex, uint256 offset) internal pure returns (bytes memory) {
        return abi.encodePacked(OP_READ_WORD, abi.encode(producerIndex, offset));
    }

    function _input(uint256 index) internal pure returns (uint256) {
        return (uint256(SRC_INPUT) << 216) | index;
    }

    function _result(uint256 index) internal pure returns (uint256) {
        return (uint256(SRC_RESULT) << 216) | index;
    }
}
