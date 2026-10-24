// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";

contract MerkleCapitalFlowSimplificationTest is CREOracleTestBase {
    function test_AllocationTransfersOnlyNewAmountWithoutReadingOracle() public {
        asset.transfer(address(adapter), 150);
        _disableOracleReads();
        vm.prank(address(delegator));
        assertEq(adapter.allocate(100), 100);
        assertEq(asset.balanceOf(account), 100);
        assertEq(asset.balanceOf(address(adapter)), 50);
        assertEq(adapter.netFlow(), 100);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.syncedSnapshotBlock(), 0);
    }

    function testFuzz_RequestDoesNothingEvenWithUnavailableOracle(uint256 amount) public {
        asset.transfer(address(adapter), 100);
        _disableOracleReads();
        vm.record();
        vm.recordLogs();
        vm.prank(address(delegator));
        adapter.requestDeallocate(amount);
        (, bytes32[] memory writes) = vm.accesses(address(adapter));
        assertEq(writes.length, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(adapter.lockedLiquidity(), 0);
        assertEq(adapter.netFlow(), 0);
    }

    function test_PullStagesReturnsWithoutReadingOracle() public {
        asset.transfer(account, 100);
        _disableOracleReads();
        vm.expectEmit(false, false, false, true, address(adapter));
        emit IMerkleAdapter.Pull(100);
        vm.prank(account);
        adapter.pull(100);
        assertEq(adapter.stagedLiquidityAt(uint48(block.number)), 100);
        assertEq(adapter.syncedSnapshotBlock(), 0);
        assertEq(asset.balanceOf(account), 0);
    }

    function test_PullStagesOnlyTransferredCash() public {
        asset.transfer(address(adapter), 50);
        asset.transfer(account, 100);
        vm.prank(account);
        adapter.pull(100);
        assertEq(asset.balanceOf(address(adapter)), 150);
        assertEq(adapter.stagedLiquidity(), 100);

        vm.prank(account);
        adapter.pull(0);
        assertEq(adapter.stagedLiquidity(), 100);
    }

    function test_DeallocationDoesNotRestageCashFreedByNAVCap() public {
        _fundPortfolio(1000);
        _stageFixtureCash();
        _advanceReport();
        _deliverWithReview(_report(400));
        assertEq(delegator.deallocate(address(adapter), 200), 200);
        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.lockedLiquidity(), 200);
        assertEq(asset.balanceOf(address(adapter)), 800);
        _stageFixtureCash();
        assertEq(adapter.stagedLiquidity(), 600);
    }

    function test_RemovedEntryPointsCannotBeCalled() public {
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSignature("push(uint256)", 0);
        calls[1] = abi.encodeWithSignature("syncReport()");
        calls[2] = abi.encodeWithSignature("pendingDeallocation()");
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(account);
            (bool success,) = address(adapter).call(calls[i]);
            assertFalse(success);
        }
    }

    function _disableOracleReads() internal {
        vm.mockCallRevert(address(oracle), abi.encodeCall(IMerkleAdapterOracle.snapshotBlock, ()), hex"deadbeef");
        vm.mockCallRevert(address(oracle), abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()), hex"deadbeef");
    }
}
