// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IOracle} from "src/interfaces/merkle-adapter/oracle/IOracle.sol";

import {OracleTestBase} from "test/adapters/merkle-adapter/oracle/Oracle.t.sol";

contract MerkleAdapterSettlementTest is OracleTestBase {
    function test_AcceptedReportImmediatelyMakesWithdrawalsDeallocatable() public {
        _fundStrategy(1000);
        delegator.requestDeallocate(address(adapter), 300);

        _next(1000);

        assertEq(oracle.totalAssets(), 700);
        assertEq(adapter.deallocatable(), 300, "accepted report must settle without a vault operation");
        assertEq(adapter.reservedAssets(), 300);
        assertEq(adapter.totalAssets(), 1000);
    }

    function test_RejectedReportPreservesAlreadyDeallocatableAssets() public {
        _fundStrategy(1000);
        delegator.requestDeallocate(address(adapter), 300);
        _next(1000);
        assertEq(adapter.deallocatable(), 300);
        delegator.requestDeallocate(address(adapter), 200);
        uint256 nonce = oracle.nonce();
        uint256 cutoff = oracle.cutoff();

        _next(0);

        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), nonce);
        assertEq(oracle.cutoff(), cutoff);
        assertEq(oracle.totalAssets(), 700);
        assertEq(adapter.deallocatable(), 300);
        assertEq(adapter.reservedAssets(), 300);
    }

    function testFuzz_TwoWithdrawalBatchesSurviveIdleReportsAndPartialPayout(
        uint16 principal,
        uint16 firstRequest,
        uint16 secondRequest,
        uint16 firstPayout,
        uint8 idleReports
    ) public {
        principal = uint16(bound(principal, 1, 10_000));
        firstRequest = uint16(bound(firstRequest, 0, principal));
        secondRequest = uint16(bound(secondRequest, 0, principal - firstRequest));
        firstPayout = uint16(bound(firstPayout, 0, firstRequest));
        idleReports = uint8(bound(idleReports, 0, 12));
        _fundStrategy(principal);
        delegator.requestDeallocate(address(adapter), firstRequest);
        _afterCutoff();
        delegator.requestDeallocate(address(adapter), uint256(firstRequest) + secondRequest);

        _next(principal);

        assertEq(adapter.deallocatable(), firstRequest);
        assertEq(delegator.deallocate(address(adapter), firstPayout), firstPayout);
        _next(principal - firstRequest);
        uint256 matured = uint256(firstRequest) + secondRequest - firstPayout;
        uint256 remainingNAV = uint256(principal) - firstRequest - secondRequest;
        assertEq(adapter.deallocatable(), matured);

        for (uint256 i; i < idleReports; ++i) {
            _next(remainingNAV);
            assertEq(adapter.deallocatable(), matured, "idle reports must not erase or duplicate a claim");
            assertEq(adapter.totalAssets(), uint256(principal) - firstPayout);
        }

        assertEq(delegator.deallocate(address(adapter), type(uint256).max), matured);
        assertEq(asset.balanceOf(adapter.vault()), uint256(firstRequest) + secondRequest);
        assertEq(asset.balanceOf(address(adapter)), remainingNAV);
        assertEq(adapter.totalAssets(), remainingNAV);
        assertEq(adapter.reservedAssets(), 0);
        assertEq(adapter.deallocatable(), 0);
        _next(remainingNAV);
        assertEq(delegator.deallocate(address(adapter), type(uint256).max), 0);
    }

    function testFuzz_LossAndInFlightReserveChangesConserveBacking(
        uint16 requested,
        uint16 surviving,
        uint16 beforeSnapshot,
        uint16 afterSnapshot,
        uint16 canceled
    ) public {
        requested = uint16(bound(requested, 1, 1000));
        surviving = uint16(bound(surviving, 0, 1000));
        beforeSnapshot = uint16(bound(beforeSnapshot, 0, 1000));
        afterSnapshot = uint16(bound(afterSnapshot, 0, 1000));
        canceled = uint16(bound(canceled, 0, uint256(beforeSnapshot) + afterSnapshot));
        _fundStrategy(1000);
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), requested);
        _afterCutoff();
        _allocate(beforeSnapshot);
        vm.startPrank(account);
        asset.transfer(address(0xdead), 1000 - surviving);
        adapter.pull(surviving);
        vm.stopPrank();
        _advanceReport();
        IOracle.Report memory captured = _report(surviving);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        _allocate(afterSnapshot);
        delegator.requestDeallocate(address(adapter), uint256(requested) + canceled);
        assertEq(delegator.deallocate(address(adapter), canceled), canceled);
        _deliverWithReview(captured);

        uint256 released = requested < surviving ? requested : surviving;
        uint256 pending = uint256(beforeSnapshot) + afterSnapshot - canceled;
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), surviving - released);
        assertEq(adapter.deallocatable(), released);
        assertEq(adapter.reservedAssets(), pending + released);
        assertEq(adapter.totalAssets(), uint256(surviving) + pending);
        assertEq(asset.balanceOf(address(adapter)), adapter.totalAssets());
        assertEq(asset.balanceOf(adapter.vault()), canceled);
        assertEq(delegator.deallocate(address(adapter), type(uint256).max), released);
        assertEq(asset.balanceOf(adapter.vault()), canceled + released);

        _next(uint256(surviving) - released + pending);

        assertEq(adapter.reservedAssets(), 0);
        assertEq(adapter.deallocatable(), 0);
        assertEq(adapter.totalAssets(), uint256(surviving) - released + pending);
        assertEq(asset.balanceOf(address(adapter)), adapter.totalAssets());
    }

    function _fundStrategy(uint256 amount) internal {
        _deliver(_report(0));
        _allocate(amount);
        _next(amount);
    }

    function _allocate(uint256 amount) internal {
        asset.transfer(adapter.vault(), amount);
        delegator.allocate(address(adapter), amount);
    }

    function _next(uint256 assets) internal {
        _advanceReport();
        _deliver(_report(assets));
    }
}
