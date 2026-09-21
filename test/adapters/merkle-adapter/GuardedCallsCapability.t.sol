// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {GuardedCallsTokenMock} from "./mocks/GuardedCallsMocks.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";

import {
    IGuardedCallsCapability as IGuarded
} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

contract GuardedCallsCapabilityTest is CapabilityTestBase {
    address internal capability;
    address internal subject;

    function setUp() public {
        subject = address(new GuardedSubject());
        capability = address(new GuardedCallsCapability());
        _deployAdapter(address(new GuardedCallsTokenMock()));
        _installCapability(adapter, capability, _guardedSelectors());
    }

    function test_DirectExecuteRequiresSelfCall() public {
        IGuarded.Call[] memory calls = new IGuarded.Call[](0);
        IGuarded.Check[] memory checks = new IGuarded.Check[](0);
        vm.expectRevert(IGuarded.InvalidCaller.selector);
        IGuarded(account).execute(calls, checks);
        vm.expectRevert(IGuarded.InvalidCaller.selector);
        IGuarded(capability).execute(calls, checks);
    }

    function testFuzz_AllComparisons(uint128 value, uint128 bound, uint8 comparison) public {
        comparison %= 3;
        IGuarded.Check[] memory checks = _check(IGuarded.Observation.After, IGuarded.Comparison(comparison), bound);
        bool allowed = comparison == 0 ? value == bound : comparison == 1 ? value >= bound : value <= bound;
        IMerkleAccount.Action[] memory actions = _actions(_calls(value), checks);
        if (!allowed) vm.expectRevert(IGuarded.CheckFailed.selector);
        MerkleAccount(payable(account)).manage(actions);
        assertEq(GuardedSubject(subject).value(), allowed ? value : 0);
    }

    function test_BeforeChecksRunBeforeAnyWrite() public {
        IGuarded.Call[] memory calls = _calls(7);
        calls[0].data = abi.encodeCall(GuardedSubject.fail, ());
        IMerkleAccount.Action[] memory actions =
            _actions(calls, _check(IGuarded.Observation.Before, IGuarded.Comparison.Equal, 1));
        vm.expectRevert(IGuarded.CheckFailed.selector);
        MerkleAccount(payable(account)).manage(actions);
        actions = _actions(_calls(7), _check(IGuarded.Observation.Before, IGuarded.Comparison.Equal, 0));
        MerkleAccount(payable(account)).manage(actions);
        assertEq(GuardedSubject(subject).value(), 7);
    }

    function testFuzz_DeltasUseBeforeAndAfterState(uint128 initial, uint128 change, bool increase) public {
        if (!increase) change = uint128(bound(change, 0, initial));
        GuardedSubject(subject).set(initial);
        uint256 finalValue = increase ? uint256(initial) + change : uint256(initial) - change;
        MerkleAccount(payable(account))
            .manage(
                _actions(
                    _calls(finalValue),
                    _check(
                        increase ? IGuarded.Observation.Increase : IGuarded.Observation.Decrease,
                        IGuarded.Comparison.Equal,
                        change
                    )
                )
            );
        assertEq(GuardedSubject(subject).value(), finalValue);
    }

    function test_OppositeDeltaRevertsAndRollsBack() public {
        GuardedSubject(subject).set(5);
        IMerkleAccount.Action[] memory actions =
            _actions(_calls(4), _check(IGuarded.Observation.Increase, IGuarded.Comparison.Equal, 0));
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
        assertEq(GuardedSubject(subject).value(), 5);
        actions = _actions(_calls(6), _check(IGuarded.Observation.Decrease, IGuarded.Comparison.Equal, 0));
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
        assertEq(GuardedSubject(subject).value(), 5);
    }

    function test_ConstantZeroRemainsAValidBound() public {
        MerkleAccount(payable(account))
            .manage(_actions(_calls(0), _check(IGuarded.Observation.After, IGuarded.Comparison.Equal, 0)));
    }

    function testFuzz_CalldataBoundReadsApprovedCallAmount(uint256 amount) public {
        IGuarded.Check[] memory checks = _check(IGuarded.Observation.Increase, IGuarded.Comparison.Equal, 0);
        checks[0].bound = IGuarded.Bound({source: IGuarded.Source.Calldata, value: 0, offset: 4});
        MerkleAccount(payable(account)).manage(_actions(_calls(amount), checks));
        assertEq(GuardedSubject(subject).value(), amount);
    }

    function test_OutOfBoundsCalldataAndCallIndexRollBackWrites() public {
        IGuarded.Check[] memory checks = _check(IGuarded.Observation.After, IGuarded.Comparison.Equal, 0);
        checks[0].bound = IGuarded.Bound({source: IGuarded.Source.Calldata, value: 1, offset: 4});
        IMerkleAccount.Action[] memory actions = _actions(_calls(8), checks);
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
        checks[0].bound = IGuarded.Bound({source: IGuarded.Source.Calldata, value: 0, offset: 5});
        actions = _actions(_calls(8), checks);
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
        assertEq(GuardedSubject(subject).value(), 0);
    }

    function test_QueryReadsChosenReturnWord() public {
        IGuarded.Check[] memory checks = _check(IGuarded.Observation.After, IGuarded.Comparison.Equal, 9);
        checks[0].query.data = abi.encodeCall(GuardedSubject.tuple, ());
        checks[0].offset = 32;
        MerkleAccount(payable(account)).manage(_actions(_calls(9), checks));
        assertEq(GuardedSubject(subject).value(), 9);
    }

    function test_ShortQueryResponseAndOverflowOffsetRollBack() public {
        IGuarded.Check[] memory checks = _check(IGuarded.Observation.After, IGuarded.Comparison.Equal, 0);
        checks[0].offset = 1;
        IMerkleAccount.Action[] memory actions = _actions(_calls(9), checks);
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
        checks[0].offset = type(uint256).max;
        actions = _actions(_calls(9), checks);
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
        assertEq(GuardedSubject(subject).value(), 0);
    }

    function test_QueriesUseStaticcallAndFailedPostconditionRollsBackAllCalls() public {
        IGuarded.Check[] memory checks = _check(IGuarded.Observation.After, IGuarded.Comparison.Equal, 9);
        checks[0].query.data = abi.encodeCall(GuardedSubject.set, (uint256(9)));
        IMerkleAccount.Action[] memory actions = _actions(_calls(7), checks);
        vm.expectRevert();
        MerkleAccount(payable(account)).manage{gas: 1_000_000}(actions);
        assertEq(GuardedSubject(subject).value(), 0);
    }

    function test_OrderedCallsReturnOriginalResultsAndUseAdapterCaller() public {
        IGuarded.Call[] memory calls = new IGuarded.Call[](2);
        calls[0] = _calls(7)[0];
        calls[1] = _calls(9)[0];
        bytes[] memory results = abi.decode(
            MerkleAccount(payable(account))
                .manage(_actions(calls, _check(IGuarded.Observation.After, IGuarded.Comparison.Equal, 9)))[0],
            (bytes[])
        );
        assertEq(abi.decode(results[0], (uint256)), 7);
        assertEq(abi.decode(results[1], (uint256)), 9);
        assertEq(GuardedSubject(subject).caller(), account);
    }

    function test_ProtocolFailureBubblesAndRollsBackEarlierCalls() public {
        IGuarded.Call[] memory calls = new IGuarded.Call[](2);
        calls[0] = _calls(7)[0];
        calls[1] = IGuarded.Call({target: subject, data: abi.encodeCall(GuardedSubject.fail, ())});
        IMerkleAccount.Action[] memory actions = _actions(calls, new IGuarded.Check[](0));
        vm.expectRevert(GuardedSubject.Failed.selector);
        MerkleAccount(payable(account)).manage(actions);
        assertEq(GuardedSubject(subject).value(), 0);
    }

    function test_EmptyCallsCanEnforceReadOnlyConditionsAndEmptyChecksAreExplicit() public {
        MerkleAccount(payable(account))
            .manage(_actions(new IGuarded.Call[](0), _check(IGuarded.Observation.Before, IGuarded.Comparison.Equal, 0)));
        MerkleAccount(payable(account)).manage(_actions(_calls(7), new IGuarded.Check[](0)));
        assertEq(GuardedSubject(subject).value(), 7);
    }

    function _calls(uint256 amount) internal view returns (IGuarded.Call[] memory calls) {
        calls = new IGuarded.Call[](1);
        calls[0] = IGuarded.Call({target: subject, data: abi.encodeCall(GuardedSubject.set, (amount))});
    }

    function _check(IGuarded.Observation observation, IGuarded.Comparison comparison, uint256 bound)
        internal
        view
        returns (IGuarded.Check[] memory checks)
    {
        checks = new IGuarded.Check[](1);
        checks[0] = IGuarded.Check({
            query: IGuarded.Call({target: subject, data: abi.encodeWithSignature("value()")}),
            offset: 0,
            observation: observation,
            comparison: comparison,
            bound: IGuarded.Bound({source: IGuarded.Source.Constant, value: bound, offset: 0})
        });
    }

    function _actions(IGuarded.Call[] memory calls, IGuarded.Check[] memory checks)
        internal
        returns (IMerkleAccount.Action[] memory)
    {
        return _publishCall(account, abi.encodeCall(IGuarded.execute, (calls, checks)));
    }
}

contract GuardedSubject {
    error Failed();
    uint256 public value;
    address public caller;

    function set(uint256 newValue) public returns (uint256) {
        value = newValue;
        caller = msg.sender;
        return newValue;
    }

    function tuple() public view returns (uint256, uint256) {
        return (123, value);
    }

    function fail() public pure {
        revert Failed();
    }
}
