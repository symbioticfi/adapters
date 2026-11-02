// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {MerkleCapitalFlowFixture} from "./MerkleCapitalFlow.t.sol";

import {MAX_SHARE} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";
import {WithdrawalQueue} from "@symbioticfi/core/src/contracts/vault/WithdrawalQueue.sol";

contract MerkleForcedExitBehaviorTest is MerkleCapitalFlowFixture {
    function testFuzz_QueueResetDoesNotChangeReturnedCashAfterLoss(bool fillQueue, bool recover, bool stageBeforeReset)
        public
    {
        _fixtureCashToAccount(1000);
        realDelegator.allocate(address(adapter), 9000);
        realDelegator.forceDeallocate(address(adapter), 3000);
        vm.prank(account);
        asset.transfer(address(0xdead), 2000);
        _deliver(_capturePortfolio());
        assertEq(adapter.totalAssets(), 8000);

        assertEq(realDelegator.limitOf(address(adapter)), 7000);
        if (stageBeforeReset) {
            vm.prank(account);
            adapter.pull(3000);
        }

        if (fillQueue) {
            address queue = realVault.withdrawalQueue();
            uint256 shares = realVault.previewWithdraw(2000);
            realVault.approve(queue, shares);
            WithdrawalQueue(queue).requestRedeem(shares, address(this));

            realVault.deposit(2000, address(this));
            assertEq(WithdrawalQueue(queue).pendingAssets(), 0);
        }

        uint256 pending = 3000;

        if (recover) {
            asset.transfer(account, 2000);
            _deliver(_capturePortfolio());
            assertEq(adapter.totalAssets(), 10_000);
        }

        uint256 settledCashBeforeReturn =
            asset.balanceOf(address(realVault)) + asset.balanceOf(realVault.withdrawalQueue());
        if (!stageBeforeReset) {
            vm.prank(account);
            adapter.pull(pending);
        }
        _deliver(_capturePortfolio());
        realDelegator.sweepPending();
        uint256 returned = stageBeforeReset ? 3000 : pending;
        assertEq(adapter.totalAssets(), (recover ? 10_000 : 8000) - returned);
        assertEq(
            asset.balanceOf(address(realVault)) + asset.balanceOf(realVault.withdrawalQueue()),
            settledCashBeforeReturn + returned
        );
    }

    function testFuzz_LimitUpdatesLeaveLiquidityUnchanged(bool forceRequested) public {
        _fixtureCashToAccount(1000);
        realDelegator.allocate(address(adapter), 9000);
        if (forceRequested) {
            realDelegator.forceDeallocate(address(adapter), 3000);
            realDelegator.setLimits(address(adapter), 10_000, MAX_SHARE);
            realDelegator.sweepPending();
        }

        address queue = realVault.withdrawalQueue();
        uint256 queued = forceRequested ? 2000 : 5000;
        realVault.approve(queue, queued);
        WithdrawalQueue(queue).requestRedeem(queued, address(this));

        if (!forceRequested) realDelegator.setLimits(address(adapter), 7000, MAX_SHARE);
        realVault.deposit(queued, address(this));

        assertEq(WithdrawalQueue(queue).pendingAssets(), 0);

        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.totalAssets(), 10_000);
    }

    function test_ForceExitAllowsAutoAllocationIntoHeadroomCreatedByLoss() public {
        _fixtureCashToAccount(1000);
        realDelegator.allocate(address(adapter), 9000);
        realDelegator.forceDeallocate(address(adapter), 3000);
        vm.prank(account);
        asset.transfer(address(0xdead), 4000);
        _deliver(_capturePortfolio());
        assertEq(adapter.totalAssets(), 6000);
        assertEq(realDelegator.absoluteLimitOf(address(adapter)), 7000);
        assertEq(realDelegator.limitOf(address(adapter)), 6000);

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        realDelegator.setAutoAllocateAdapters(adapters);
        realVault.deposit(1000, address(this));
        assertEq(realDelegator.limitOf(address(adapter)), 7000);
        assertEq(adapter.totalAssets(), 7000);
        assertEq(asset.balanceOf(account), 7000);

        assertEq(asset.balanceOf(address(realVault)), 0);

        vm.prank(account);
        adapter.pull(3000);
        _deliver(_capturePortfolio());
        realDelegator.sweepPending();
        assertEq(adapter.totalAssets(), 4000);
        assertEq(asset.balanceOf(account), 4000);
        assertEq(asset.balanceOf(address(realVault)), 3000);
        assertEq(realVault.totalAssets(), 7000);
    }
}
