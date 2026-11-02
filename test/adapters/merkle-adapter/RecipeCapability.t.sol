// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipeTokenMock} from "./mocks/RecipeCapabilityMocks.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {
    IRecipes as R,
    OP_ADD,
    OP_APPROVE,
    OP_CALL,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MANAGE,
    OP_READ,
    OP_SUB,
    SRC_INPUT,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract RecipeCapabilityTest is CapabilityTestBase {
    RecipeSubject internal subject;
    address internal implementation;

    function setUp() public {
        subject = new RecipeSubject();
        _deployAdapter(address(new RecipeTokenMock()));
        implementation = address(new RecipeCapability());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IRecipeCapability.execute.selector;
        _installCapability(adapter, implementation, selectors);
    }

    function test_LiteralTargetRetainsAccountCaller() public {
        uint256 target = uint160(address(subject));
        bytes[] memory queries = new bytes[](1);
        queries[0] = abi.encode(target, abi.encodeWithSignature("value()"), new uint256[](0), uint256(0));
        bytes[] memory steps = new bytes[](3);
        steps[0] = abi.encodePacked(OP_ADD, abi.encode(uint256(uint160(address(subject))), uint256(0)));
        steps[1] = abi.encodePacked(
            OP_CALL, abi.encode(target, abi.encodeCall(RecipeSubject.set, (uint256(7))), new uint256[](0))
        );
        steps[2] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = uint160(address(subject));
        bytes memory response = _manage(account, abi.encodeCall(IRecipeCapability.execute, (queries, steps, inputs)));
        assertEq(abi.decode(response, (uint256[]))[2], 7);
        assertEq(subject.caller(), account);
    }

    function testFuzz_OversizedTargetIsRejected(bool read, uint256 target) public {
        target = bound(target, uint256(type(uint160).max) + 1, type(uint256).max);
        bytes[] memory queries = new bytes[](1);
        queries[0] = abi.encode(target, abi.encodeWithSignature("value()"), new uint256[](0), uint256(0));
        bytes[] memory steps = new bytes[](1);
        steps[0] = read
            ? abi.encodePacked(OP_READ, abi.encode(uint256(0)))
            : abi.encodePacked(
                OP_CALL, abi.encode(target, abi.encodeCall(RecipeSubject.set, (uint256(7))), new uint256[](0))
            );
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = target;
        IMerkleAccount.Action[] memory actions = _actions(queries, steps, inputs);
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
        assertEq(subject.value(), 0);
    }

    /// forge-config: default.isolate = true
    function test_RecipeBindsComputedAmountAndChecksAccountState() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = abi.encode(address(subject), abi.encodeWithSignature("value()"), new uint256[](0), uint256(0));
        bytes[] memory steps = new bytes[](5);
        steps[0] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        steps[1] = abi.encodePacked(OP_ADD, abi.encode(_result(0), _input(0)));
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = (uint256(4) << 224) | _result(1);
        steps[2] = abi.encodePacked(
            OP_CALL, abi.encode(address(subject), abi.encodeCall(RecipeSubject.set, (uint256(0))), bindings)
        );
        steps[3] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        steps[4] = abi.encodePacked(OP_EQUAL, abi.encode(_result(3), _result(1)));
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 7;
        bytes memory response = _manage(account, abi.encodeCall(IRecipeCapability.execute, (queries, steps, inputs)));
        vm.snapshotGasLastCall("RecipeCapability", "executeChecksAndBindings");
        uint256[] memory values = abi.decode(response, (uint256[]));
        assertEq(subject.value(), 7);
        assertEq(subject.caller(), account);
        assertEq(values[0], 0);
        assertEq(values[1], 7);
        assertEq(values[3], 7);
    }

    /// forge-config: default.isolate = true
    function test_DirectExecuteRequiresSelfCall() public {
        vm.expectRevert(IRecipeCapability.InvalidCaller.selector);
        vm.startSnapshotGas("RecipeCapability", "executeDirectAccountRejected");
        IRecipeCapability(account).execute(new bytes[](0), new bytes[](0), new uint256[](0));
        vm.stopSnapshotGas();
        vm.expectRevert(IRecipeCapability.InvalidCaller.selector);
        vm.startSnapshotGas("RecipeCapability", "executeDirectImplementationRejected");
        IRecipeCapability(implementation).execute(new bytes[](0), new bytes[](0), new uint256[](0));
        vm.stopSnapshotGas();
    }

    function testFuzz_AccountManagementInstructionsAreRejected(bool approve) public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(approve ? OP_APPROVE : OP_MANAGE, "");
        IMerkleAccount.Action[] memory actions = _actions(new bytes[](0), steps, new uint256[](0));
        vm.expectRevert(R.InvalidOperation.selector);
        MerkleAccount(payable(account)).manage(actions);
    }

    function testFuzz_ComparisonsConstrainTheWrittenValue(uint128 value, uint128 limit, uint8 comparison) public {
        comparison %= 3;
        bool allowed = comparison == 0 ? value == limit : comparison == 1 ? value >= limit : value <= limit;
        bytes[] memory steps = new bytes[](3);
        steps[0] = _set(value);
        steps[1] = _read();
        steps[2] = abi.encodePacked(
            comparison == 0 ? OP_EQUAL : OP_LESS_OR_EQUAL,
            comparison == 1 ? abi.encode(_literal(limit), _result(1)) : abi.encode(_result(1), _literal(limit))
        );
        IMerkleAccount.Action[] memory actions = _actions(_queries(), steps, new uint256[](0));
        if (!allowed) vm.expectRevert(R.CheckFailed.selector);
        MerkleAccount(payable(account)).manage(actions);
        assertEq(subject.value(), allowed ? value : 0);
    }

    /// forge-config: default.isolate = true
    function test_BeforeCheckRunsBeforeAnyWrite() public {
        bytes[] memory steps = new bytes[](3);
        steps[0] = _read();
        steps[1] = abi.encodePacked(OP_EQUAL, abi.encode(_result(0), _literal(1)));
        steps[2] = abi.encodePacked(
            OP_CALL, abi.encode(address(subject), abi.encodeCall(RecipeSubject.fail, ()), new uint256[](0))
        );
        IMerkleAccount.Action[] memory actions = _actions(_queries(), steps, new uint256[](0));
        vm.expectRevert(R.CheckFailed.selector);
        vm.startSnapshotGas("RecipeCapability", "executeCheckBeforeFailure");
        MerkleAccount(payable(account)).manage(actions);
        vm.stopSnapshotGas();
    }

    function testFuzz_CheckedDeltasUseBeforeAndAfterValues(uint128 initial, uint128 change, bool increase) public {
        if (!increase) change = uint128(bound(change, 0, initial));
        subject.set(initial);
        uint256 finalValue = increase ? uint256(initial) + change : initial - change;
        bytes[] memory steps = _delta(finalValue, increase, _literal(change));
        _manage(account, abi.encodeCall(IRecipeCapability.execute, (_queries(), steps, new uint256[](0))));
        assertEq(subject.value(), finalValue);
    }

    function test_OppositeDeltaRevertsAndRollsBack() public {
        subject.set(5);
        IMerkleAccount.Action[] memory actions = _actions(_queries(), _delta(4, true, _literal(0)), new uint256[](0));
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
        assertEq(subject.value(), 5);
        actions = _actions(_queries(), _delta(6, false, _literal(0)), new uint256[](0));
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
        assertEq(subject.value(), 5);
    }

    /// forge-config: default.isolate = true
    function test_PostconditionRollsBackEveryEarlierCall() public {
        bytes[] memory steps = new bytes[](4);
        steps[0] = _set(7);
        steps[1] = _set(9);
        steps[2] = _read();
        steps[3] = abi.encodePacked(OP_EQUAL, abi.encode(_result(2), _literal(8)));
        IMerkleAccount.Action[] memory actions = _actions(_queries(), steps, new uint256[](0));
        vm.expectRevert(R.CheckFailed.selector);
        vm.startSnapshotGas("RecipeCapability", "executeCheckAfterRollback");
        MerkleAccount(payable(account)).manage(actions);
        vm.stopSnapshotGas();
        assertEq(subject.value(), 0);
        assertEq(subject.caller(), address(0));
    }

    /// forge-config: default.isolate = true
    function test_ProtocolFailureBubblesAndRollsBackEarlierCalls() public {
        bytes[] memory steps = new bytes[](2);
        steps[0] = _set(7);
        steps[1] = abi.encodePacked(
            OP_CALL, abi.encode(address(subject), abi.encodeCall(RecipeSubject.fail, ()), new uint256[](0))
        );
        IMerkleAccount.Action[] memory actions = _actions(new bytes[](0), steps, new uint256[](0));
        vm.expectRevert(RecipeSubject.Failed.selector);
        vm.startSnapshotGas("RecipeCapability", "executeProtocolFailureRollback");
        MerkleAccount(payable(account)).manage(actions);
        vm.stopSnapshotGas();
        assertEq(subject.value(), 0);
    }

    function test_QueryUsesStaticcall() public {
        bytes[] memory queries = _queries();
        queries[0] =
            abi.encode(address(subject), abi.encodeCall(RecipeSubject.set, (uint256(1))), new uint256[](0), uint256(0));
        bytes[] memory steps = new bytes[](1);
        steps[0] = _read();
        IMerkleAccount.Action[] memory actions = _actions(queries, steps, new uint256[](0));
        vm.expectRevert();
        MerkleAccount(payable(account)).manage{gas: 1_000_000}(actions);
        assertEq(subject.value(), 0);
    }

    /// forge-config: default.isolate = true
    function test_CallbackCannotEnterTheCapability() public {
        bytes memory callback =
            abi.encodeCall(IRecipeCapability.execute, (new bytes[](0), new bytes[](0), new uint256[](0)));
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(
            OP_CALL,
            abi.encode(address(subject), abi.encodeCall(RecipeSubject.callback, (account, callback)), new uint256[](0))
        );
        IMerkleAccount.Action[] memory actions = _actions(new bytes[](0), steps, new uint256[](0));
        vm.expectRevert(IRecipeCapability.InvalidCaller.selector);
        vm.startSnapshotGas("RecipeCapability", "executeCallbackRejected");
        MerkleAccount(payable(account)).manage(actions);
        vm.stopSnapshotGas();
    }

    /// forge-config: default.isolate = true
    function test_EmptyAndReadOnlyRecipes() public {
        bytes memory response = _manage(
            account, abi.encodeCall(IRecipeCapability.execute, (new bytes[](0), new bytes[](0), new uint256[](0)))
        );
        vm.snapshotGasLastCall("RecipeCapability", "executeEmpty");
        uint256[] memory empty = abi.decode(response, (uint256[]));
        assertEq(empty.length, 0);
        bytes[] memory steps = new bytes[](2);
        steps[0] = _read();
        steps[1] = abi.encodePacked(OP_EQUAL, abi.encode(_result(0), _literal(0)));
        _manage(account, abi.encodeCall(IRecipeCapability.execute, (_queries(), steps, new uint256[](0))));
        vm.snapshotGasLastCall("RecipeCapability", "executeReadAndCheck");
    }

    function _delta(uint256 finalValue, bool increase, uint256 change) internal view returns (bytes[] memory steps) {
        steps = new bytes[](5);
        steps[0] = _read();
        steps[1] = _set(finalValue);
        steps[2] = _read();
        steps[3] = abi.encodePacked(
            OP_SUB, increase ? abi.encode(_result(2), _result(0)) : abi.encode(_result(0), _result(2))
        );
        steps[4] = abi.encodePacked(OP_EQUAL, abi.encode(_result(3), change));
    }

    function _queries() internal view returns (bytes[] memory queries) {
        queries = new bytes[](1);
        queries[0] = abi.encode(address(subject), abi.encodeWithSignature("value()"), new uint256[](0), uint256(0));
    }

    function _read() internal pure returns (bytes memory) {
        return abi.encodePacked(OP_READ, abi.encode(uint256(0)));
    }

    function _set(uint256 value) internal view returns (bytes memory) {
        return abi.encodePacked(
            OP_CALL, abi.encode(address(subject), abi.encodeCall(RecipeSubject.set, (value)), new uint256[](0))
        );
    }

    function _actions(bytes[] memory queries, bytes[] memory steps, uint256[] memory inputs)
        internal
        returns (IMerkleAccount.Action[] memory)
    {
        return _publishCall(account, abi.encodeCall(IRecipeCapability.execute, (queries, steps, inputs)));
    }

    function _literal(uint256 value) internal pure returns (uint256) {
        assertLe(value, type(uint216).max);
        return value;
    }

    function _result(uint256 index) internal pure returns (uint256) {
        assertLe(index, type(uint216).max);
        return (uint256(SRC_RESULT) << 216) | index;
    }

    function _input(uint256 index) internal pure returns (uint256) {
        assertLe(index, type(uint216).max);
        return (uint256(SRC_INPUT) << 216) | index;
    }
}

contract RecipeSubject {
    error Failed();

    function fail() public pure {
        revert Failed();
    }

    function callback(address target, bytes calldata data) public {
        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    uint256 public value;
    address public caller;

    function set(uint256 amount) public {
        value = amount;
        caller = msg.sender;
    }
}
