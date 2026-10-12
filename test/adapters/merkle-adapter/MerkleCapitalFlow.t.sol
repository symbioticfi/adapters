// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {
    ICREOracle,
    ORACLE_LIMIT_PRECISION,
    ORACLE_LIMITS_ROLE,
    ORACLE_GUARD_ROLE
} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";
import {createMerkleAccountFactory} from "test/helpers/MerkleAccountFactory.sol";
import {AdapterRegistry} from "@symbioticfi/core/src/contracts/AdapterRegistry.sol";
import {VaultFactory} from "@symbioticfi/core/src/contracts/VaultFactory.sol";
import {UniversalDelegatorFactory} from "@symbioticfi/core/src/contracts/UniversalDelegatorFactory.sol";
import {WithdrawalQueueFactory} from "@symbioticfi/core/src/contracts/WithdrawalQueueFactory.sol";
import {ProtocolFeeRegistry} from "@symbioticfi/core/src/contracts/ProtocolFeeRegistry.sol";
import {VaultV2} from "@symbioticfi/core/src/contracts/vault/VaultV2.sol";
import {WithdrawalQueue} from "@symbioticfi/core/src/contracts/vault/WithdrawalQueue.sol";
import {UniversalDelegator} from "@symbioticfi/core/src/contracts/delegator/UniversalDelegator.sol";
import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {IVaultV2, VAULT_V2_VERSION} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";
import {
    IUniversalDelegator,
    ALLOCATE_ROLE,
    DEALLOCATE_ROLE,
    UNIVERSAL_DELEGATOR_VERSION,
    MAX_SHARE
} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";

contract CapitalFlowPlaceholder is MigratableEntity {
    constructor(address factory) MigratableEntity(factory) {}
}

/// @dev Exposes the production transfer bodies separately from the public methods' automatic cash sweeps.
contract CapitalFlowDelegator is UniversalDelegator {
    constructor(address registry, address factory) UniversalDelegator(registry, factory) {}

    function allocateWithoutSweep(address adapter, uint256 amount) external returns (uint256) {
        return _allocate(adapter, amount);
    }

    function returnWithoutSweep(address adapter, uint256 amount) external returns (uint256) {
        return _deallocate(adapter, amount);
    }
}

/// @dev Uses production vault, delegator, adapter and oracle, with the real factory initialization paths.
abstract contract MerkleCapitalFlowFixture is CREOracleTestBase {
    VaultV2 internal realVault;
    UniversalDelegator internal realDelegator;

    function _setUpAcceptedWorkflow() internal override {}

    function setUp() public virtual override {
        super.setUp();
        VaultFactory vaults = new VaultFactory(address(this));
        UniversalDelegatorFactory delegators = new UniversalDelegatorFactory(address(this));
        WithdrawalQueueFactory queues = new WithdrawalQueueFactory(address(this));
        AdapterRegistry registry = new AdapterRegistry(address(this));
        ProtocolFeeRegistry fees = new ProtocolFeeRegistry(address(this));
        fees.setGlobalReceiver(address(this));
        queues.whitelist(address(new WithdrawalQueue(address(queues))));
        for (uint64 i = 1; i < VAULT_V2_VERSION; ++i) {
            vaults.whitelist(address(new CapitalFlowPlaceholder(address(vaults))));
        }
        vaults.whitelist(address(new VaultV2(address(vaults), address(delegators), address(fees), address(queues))));
        for (uint64 i = 1; i < UNIVERSAL_DELEGATOR_VERSION; ++i) {
            delegators.whitelist(address(new CapitalFlowPlaceholder(address(delegators))));
        }
        delegators.whitelist(address(new CapitalFlowDelegator(address(registry), address(delegators))));
        IVaultV2.InitParams memory params;
        params.name = "Capital flow vault";
        params.symbol = "CFV";
        params.asset = address(asset);
        params.defaultAdminRoleHolder = address(this);
        params.delegatorParams = abi.encode(
            IUniversalDelegator.InitParams({
                allocateRoleHolder: address(this),
                deallocateRoleHolder: address(this),
                addAdapterRoleHolder: address(this),
                swapAdaptersRoleHolder: address(this),
                defaultAdminRoleHolder: address(this),
                removeAdapterRoleHolder: address(this),
                forceDeallocateRoleHolder: address(this),
                setAdapterLimitsRoleHolder: address(this),
                setAutoAllocateAdaptersRoleHolder: address(this)
            })
        );
        realVault = VaultV2(vaults.create(VAULT_V2_VERSION, address(this), abi.encode(params)));
        realDelegator = UniversalDelegator(realVault.delegator());
        AdapterFactory adapters = new AdapterFactory(address(this));
        address accounts = createMerkleAccountFactory(
            address(this),
            address(adapters),
            address(new RootRegistry(address(this))),
            address(new CapabilitiesRegistry(address(this)))
        );
        adapters.whitelist(address(new MerkleAdapter(address(vaults), address(adapters), address(factory), accounts)));
        adapter = MerkleAdapter(
            payable(adapters.create(
                    1, address(this), abi.encode(address(realVault), abi.encode(merkleAdapterInitParams(address(this))))
                ))
        );
        account = adapter.account();
        oracle = CREOracle(adapter.oracle());
        _proposeWorkflow(address(oracle), WORKFLOW);
        _acceptWorkflow(address(oracle), WORKFLOW);
        oracle.grantRole(ORACLE_GUARD_ROLE, address(this));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(uint32(ORACLE_LIMIT_PRECISION), uint32(ORACLE_LIMIT_PRECISION), 1e18);
        _deliver(_report(0));
        registry.setWhitelistedStatus(address(realVault), address(adapter), true);
        realDelegator.addAdapter(address(adapter));
        realDelegator.setLimits(address(adapter), type(uint256).max, MAX_SHARE);
        asset.approve(address(realVault), type(uint256).max);
        realVault.deposit(10_000, address(this));
        realDelegator.allocate(address(adapter), 1000);
    }

    function _portfolioCash() internal view returns (uint256) {
        return asset.balanceOf(address(adapter)) + asset.balanceOf(account);
    }

    function _capturePortfolio() internal returns (ICREOracle.Report memory result) {
        uint48 reportBlock = uint48(vm.getBlockNumber() + 1);
        uint48 reportTime = uint48(vm.getBlockTimestamp() + 1);
        vm.roll(reportBlock);
        vm.warp(reportTime);
        result = ICREOracle.Report(block.chainid, address(adapter), _portfolioCash(), reportBlock, reportTime);
        vm.roll(uint256(reportBlock) + 1);
        vm.warp(uint256(reportTime) + 1);
    }
}

contract MerkleCapitalFlowTest is MerkleCapitalFlowFixture {
    function test_AllocationIsImmediatelyInvestableButReturnsRequireReport() public {
        vm.prank(account);
        adapter.push(600);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(realDelegator.deallocate(address(adapter), 1000), 0);
        vm.prank(address(realDelegator));
        adapter.requestDeallocate(1000);
        assertEq(adapter.stagedLiquidity(), 400);
        assertEq(realDelegator.deallocate(address(adapter), 1000), 0);
        _deliver(_capturePortfolio());
        assertEq(realDelegator.deallocate(address(adapter), 1000), 400);
        assertEq(adapter.totalAssets(), 600);
        assertEq(realVault.totalAssets(), 10_000);
        vm.prank(address(realDelegator));
        adapter.requestDeallocate(150);
        vm.prank(account);
        adapter.pull(150);
        assertEq(realDelegator.deallocate(address(adapter), 150), 0);
        _deliver(_capturePortfolio());
        assertEq(realDelegator.deallocate(address(adapter), 150), 150);
        assertEq(adapter.totalAssets(), 450);
        assertEq(realVault.totalAssets(), 10_000);
    }

    function test_DelayedReportDoesNotCountReleasedAndReturnedCashTwice() public {
        _releaseRealPortfolio(1000);
        ICREOracle.Report memory report = _capturePortfolio();
        assertEq(CapitalFlowDelegator(address(realDelegator)).returnWithoutSweep(address(adapter), 150), 150);
        _deliver(report);
        assertEq(adapter.totalAssets(), 850);
        assertEq(realVault.totalAssets(), 10_000);
        _deliver(_capturePortfolio());
        assertEq(adapter.totalAssets(), 850);
        assertEq(realVault.totalAssets(), 10_000);
    }

    function test_RealDelegatorCannotNetAllocationsAgainstUnreportedRequests() public {
        vm.prank(address(realDelegator));
        adapter.requestDeallocate(300);
        assertEq(CapitalFlowDelegator(address(realDelegator)).allocateWithoutSweep(address(adapter), 200), 200);
        assertEq(adapter.pendingDeallocation(), 300);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.netFlow(), 1200);
        assertEq(realVault.totalAssets(), 10_000);
        assertEq(CapitalFlowDelegator(address(realDelegator)).returnWithoutSweep(address(adapter), 200), 0);
        assertEq(CapitalFlowDelegator(address(realDelegator)).allocateWithoutSweep(address(adapter), 200), 200);
        assertEq(adapter.pendingDeallocation(), 300);
        assertEq(adapter.netFlow(), 1400);
        assertEq(realVault.totalAssets(), 10_000);
    }

    function test_ProfitCanMakeLifetimeNetFlowNegativeAfterRelease() public {
        asset.transfer(address(adapter), 200);
        assertEq(realDelegator.deallocatable(), 0);
        _releaseRealPortfolio(1200);
        assertEq(realDelegator.deallocate(address(adapter), 1200), 1200);
        assertEq(adapter.netFlow(), -200);
        assertEq(adapter.totalAssets(), 0);
        assertEq(realVault.totalAssets(), 10_200);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.netFlowAt(uint48(vm.getBlockNumber() - 1)), -200);
    }

    function test_FullExitLossIsRecognizedBeforeCashBecomesReturnable() public {
        vm.prank(account);
        adapter.push(100);
        vm.prank(account);
        asset.transfer(address(0xdead), 100);
        vm.prank(address(realDelegator));
        adapter.requestDeallocate(1000);
        assertEq(realDelegator.deallocate(address(adapter), 1000), 0);
        _deliver(_capturePortfolio());
        assertEq(adapter.totalAssets(), 900);
        assertEq(adapter.pendingDeallocation(), 900);
        assertEq(realVault.totalAssets(), 9900);
        assertEq(realDelegator.deallocate(address(adapter), 1000), 900);
        assertEq(adapter.totalAssets(), 0);
        assertEq(_portfolioCash(), 0);
        assertEq(realVault.totalAssets(), 9900);
    }

    function test_QueuePricesBothHalvesAfterReportedLoss() public {
        uint256 total = 10_000e18;
        uint256 returned = 4000e18;
        realVault.deposit(total - 10_000, address(this));
        realDelegator.allocate(address(adapter), total - 1000);
        vm.prank(account);
        adapter.push(total);
        assertEq(asset.balanceOf(address(realVault)), 0);
        uint256 shares = realVault.balanceOf(address(this)) / 2;
        WithdrawalQueue queue = WithdrawalQueue(realVault.withdrawalQueue());
        realVault.approve(address(queue), shares);
        uint256 tokenId = queue.requestRedeem(shares, address(this));
        vm.prank(account);
        asset.transfer(address(0xdead), 2000e18);
        vm.prank(account);
        adapter.pull(returned);
        realDelegator.sweepPending();
        assertEq(asset.balanceOf(address(queue)), 0);
        assertEq(queue.pendingShares(), shares);
        assertEq(realDelegator.deallocatable(), 0);
        _deliver(_capturePortfolio());
        assertEq(adapter.totalAssets(), 8000e18);
        realDelegator.sweepPending();
        // The queue's existing previewDeposit capacity calculation leaves one share/asset unit of dust.
        assertEq(asset.balanceOf(address(queue)), returned - 1);
        assertEq(queue.pendingShares(), 1);
        assertEq(realVault.totalAssets(), returned + 1);
        assertEq(realVault.previewRedeem(realVault.balanceOf(address(this))), returned);
        uint256 before = asset.balanceOf(address(this));
        (uint256 claimedAssets, uint256 claimedShares) = queue.claim(tokenId, address(this));
        assertEq(claimedAssets, returned - 1);
        assertEq(claimedShares, shares - 1);
        assertEq(asset.balanceOf(address(this)) - before, returned - 1);
        assertEq(adapter.totalAssets(), returned);
    }

    function test_DelayedSnapshotBeforeReturnCannotReleaseItsCash() public {
        vm.prank(account);
        adapter.push(1000);
        vm.prank(address(realDelegator));
        adapter.requestDeallocate(600);
        ICREOracle.Report memory report = _capturePortfolio();
        vm.prank(account);
        adapter.pull(400);
        assertEq(adapter.stagedLiquidityAt(report.snapshotBlock), 0);
        _deliver(report);
        assertEq(realDelegator.deallocatable(), 0);
        assertEq(CapitalFlowDelegator(address(realDelegator)).returnWithoutSweep(address(adapter), 600), 0);
        _deliver(_capturePortfolio());
        assertEq(CapitalFlowDelegator(address(realDelegator)).returnWithoutSweep(address(adapter), 600), 400);
        assertEq(adapter.pendingDeallocation(), 200);
    }

    function test_StagingCallsCannotPostponeOrIncludeLaterReturns() public {
        vm.prank(account);
        adapter.push(1000);
        vm.prank(address(realDelegator));
        adapter.requestDeallocate(600);
        vm.prank(account);
        adapter.pull(1);
        uint48 firstBlock = uint48(vm.getBlockNumber());
        ICREOracle.Report memory report = _capturePortfolio();
        vm.prank(account);
        adapter.pull(399);
        adapter.stageLiquidity();
        assertEq(adapter.stagedLiquidity(), 400);
        assertEq(adapter.stagedLiquidityAt(firstBlock), 1);
        _deliver(report);
        assertEq(adapter.releasedLiquidity(), 1);
        assertEq(adapter.stagedLiquidity(), 399);
        assertEq(adapter.stagedLiquidityAt(report.snapshotBlock), 1);
        assertEq(CapitalFlowDelegator(address(realDelegator)).returnWithoutSweep(address(adapter), 600), 1);
        _deliver(_capturePortfolio());
        assertEq(CapitalFlowDelegator(address(realDelegator)).returnWithoutSweep(address(adapter), 600), 399);
        assertEq(adapter.pendingDeallocation(), 200);
        vm.prank(account);
        adapter.pull(200);
        assertEq(CapitalFlowDelegator(address(realDelegator)).returnWithoutSweep(address(adapter), 600), 0);
        _deliver(_capturePortfolio());
        assertEq(CapitalFlowDelegator(address(realDelegator)).returnWithoutSweep(address(adapter), 600), 200);
        assertEq(adapter.pendingDeallocation(), 0);
    }

    function test_StaleRealDelegatorTransferRollsBackFlowAndCash() public {
        _releaseRealPortfolio(1000);
        vm.warp(uint256(oracle.snapshotTimestamp()) + oracle.MAX_REPORT_AGE() + 1);
        vm.expectRevert(IMerkleAdapterOracle.OracleStale.selector);
        realDelegator.deallocate(address(adapter), 150);
        assertEq(adapter.netFlow(), 1000);
        assertEq(_portfolioCash(), 1000);
        assertEq(adapter.releasedLiquidity(), 1000);
        assertEq(asset.balanceOf(address(realVault)), 9000);
    }

    function test_PublicCuratorExitWaitsForManagedReturnAndCoveringReportBeforeRemoval() public {
        _managePortfolioTransfer(abi.encodeCall(IMerkleAdapter.push, (1000)));
        (uint256 deallocated, uint256 pending) = realDelegator.forceDeallocate(address(adapter), 2000);
        assertEq(deallocated, 0);
        assertEq(pending, 1000);
        assertEq(adapter.pendingDeallocation(), 1000);
        assertEq(realDelegator.absoluteLimitOf(address(adapter)), 0);
        assertEq(realDelegator.shareLimitOf(address(adapter)), MAX_SHARE);
        assertEq(realDelegator.allocate(address(adapter), 1), 0);
        vm.expectRevert(IUniversalDelegator.AdapterHasAssets.selector);
        realDelegator.removeAdapter(address(adapter));

        ICREOracle.Report memory beforeReturn = _capturePortfolio();
        _managePortfolioTransfer(abi.encodeCall(IMerkleAdapter.pull, (1000)));
        assertEq(asset.balanceOf(account), 0);
        assertEq(adapter.stagedLiquidity(), 1000);
        assertEq(adapter.stagedLiquidityAt(beforeReturn.snapshotBlock), 0);
        _deliver(beforeReturn);
        assertEq(realDelegator.sweepPending(), 0);
        assertEq(realDelegator.deallocatable(), 0);
        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(realVault)), 9000);

        _deliver(_capturePortfolio());
        assertEq(adapter.releasedLiquidity(), 1000);
        assertEq(realDelegator.sweepPending(), 0);
        assertEq(adapter.pendingDeallocation(), 0);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.totalAssets(), 0);
        assertEq(adapter.netFlow(), 0);
        assertEq(_portfolioCash(), 0);
        assertEq(asset.balanceOf(address(realVault)), 10_000);
        assertEq(realVault.totalAssets(), 10_000);

        realDelegator.removeAdapter(address(adapter));
        assertEq(realDelegator.getAdaptersLength(), 0);
        assertEq(realDelegator.totalAssets(), 0);
        assertFalse(realDelegator.hasRole(ALLOCATE_ROLE, address(adapter)));
        assertFalse(realDelegator.hasRole(DEALLOCATE_ROLE, address(adapter)));
        assertEq(realVault.totalAssets(), 10_000);
    }

    function test_PublicCuratorExitCompletesAfterConcurrentQueueDemandIsFilled() public {
        assertEq(realDelegator.allocate(address(adapter), 9000), 9000);
        _managePortfolioTransfer(abi.encodeCall(IMerkleAdapter.push, (10_000)));
        address queue = realVault.withdrawalQueue();
        realVault.approve(queue, 5000);
        uint256 tokenId = WithdrawalQueue(queue).requestRedeem(5000, address(this));
        assertEq(WithdrawalQueue(queue).pendingAssets(), 5000);
        assertEq(adapter.pendingDeallocation(), 5000);

        (uint256 deallocated, uint256 pending) = realDelegator.forceDeallocate(address(adapter), 10_000);
        assertEq(deallocated, 0);
        assertEq(pending, 10_000);
        // The public force call's final sweep replaces its request with the queue's cumulative demand.
        assertEq(adapter.pendingDeallocation(), 5000);
        assertEq(realDelegator.absoluteLimitOf(address(adapter)), 0);
        assertEq(realDelegator.shareLimitOf(address(adapter)), MAX_SHARE);
        _managePortfolioTransfer(abi.encodeCall(IMerkleAdapter.pull, (10_000)));
        assertEq(adapter.stagedLiquidity(), 5000);
        assertEq(realDelegator.sweepPending(), 5000);
        assertEq(asset.balanceOf(queue), 0);
        assertEq(realDelegator.deallocatable(), 0);

        _deliver(_capturePortfolio());
        assertEq(realDelegator.sweepPending(), 0);
        assertEq(WithdrawalQueue(queue).pendingShares(), 0);
        assertEq(asset.balanceOf(queue), 5000);
        assertEq(adapter.pendingDeallocation(), 0);
        assertEq(adapter.totalAssets(), 5000);
        assertEq(asset.balanceOf(address(adapter)), 5000);
        assertEq(adapter.freeAssets(), 0);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(realVault.totalAssets(), 5000);
        assertEq(realDelegator.allocate(address(adapter), 1), 0);
        vm.expectRevert(IUniversalDelegator.AdapterHasAssets.selector);
        realDelegator.removeAdapter(address(adapter));

        // Once queue demand is satisfied, request the remaining curator exit through the public delegator.
        (deallocated, pending) = realDelegator.forceDeallocate(address(adapter), type(uint256).max);
        assertEq(deallocated, 0);
        assertEq(pending, 5000);
        assertEq(adapter.pendingDeallocation(), 5000);
        assertEq(adapter.stagedLiquidity(), 5000);
        assertEq(realDelegator.deallocatable(), 0);
        _deliver(_capturePortfolio());
        assertEq(realDelegator.sweepPending(), 0);
        assertEq(adapter.totalAssets(), 0);
        assertEq(adapter.netFlow(), 0);
        assertEq(adapter.pendingDeallocation(), 0);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(_portfolioCash(), 0);
        assertEq(asset.balanceOf(address(realVault)), 5000);
        assertEq(realVault.totalAssets(), 5000);
        realDelegator.removeAdapter(address(adapter));
        assertEq(realDelegator.getAdaptersLength(), 0);
        assertEq(realDelegator.totalAssets(), 0);
        assertFalse(realDelegator.hasRole(ALLOCATE_ROLE, address(adapter)));
        assertFalse(realDelegator.hasRole(DEALLOCATE_ROLE, address(adapter)));

        uint256 balanceBefore = asset.balanceOf(address(this));
        (uint256 claimedAssets, uint256 claimedShares) = WithdrawalQueue(queue).claim(tokenId, address(this));
        assertEq(claimedAssets, 5000);
        assertEq(claimedShares, 5000);
        assertTrue(WithdrawalQueue(queue).isClaimed(tokenId));
        assertEq(asset.balanceOf(address(this)) - balanceBefore, 5000);
        assertEq(asset.balanceOf(queue), 0);
        assertEq(realVault.previewRedeem(realVault.balanceOf(address(this))), 5000);
        assertEq(realVault.totalAssets() + claimedAssets, 10_000);
    }

    function _managePortfolioTransfer(bytes memory data) internal {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = IMerkleAccount.Action({
            target: address(adapter), value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
        bytes32 leaf = keccak256(
            bytes.concat(
                keccak256(abi.encode(address(adapter), bytes1(0), keccak256(actions[0].dataMask), keccak256(data)))
            )
        );
        RootRegistry(IMerkleAccount(account).ROOT_REGISTRY()).setRoot(account, leaf);
        IMerkleAccount(account).acceptRoot(leaf);
        IMerkleAccount(account).grantRole(leaf, address(this));
        IMerkleAccount(account).manage(actions);
    }

    function _releaseRealPortfolio(uint256 amount) internal {
        vm.prank(address(realDelegator));
        adapter.requestDeallocate(amount);
        _deliver(_capturePortfolio());
    }
}
