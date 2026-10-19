// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IChainlinkWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/IChainlinkWorkflowRegistry.sol";

// Research harness: the cutoff tests target a proposed scheduling formula, not the current implementation.
contract MerkleScheduleRegistryResearchTest is CREOracleTestBase {
    bytes32 constant NEXT = keccak256("research replacement");

    function _allocate(uint256 amount) internal {
        asset.transfer(adapter.vault(), amount);
        delegator.allocate(address(adapter), amount);
    }

    function _freezeFundedPortfolio() internal returns (ICREOracle.Report memory rejected) {
        _deliver(_report(0));
        _allocate(1000);
        _advanceReport();
        _deliver(_report(1000));
        vm.warp(10_195);
        _allocate(200);
        asset.transfer(account, 2000);
        vm.warp(10_200);
        vm.roll(block.number + 1);
        rejected = _report(3000);
        _deliver(rejected);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.cutoff(), 10_190);
    }

    function test_ProposedCutoffPreservesSameBlockAccountingAndNextCron() public {
        ICREOracle.Report memory rejected = _freezeFundedPortfolio();
        vm.warp(10_291);
        vm.roll(block.number + 1);
        oracle.unfreezeOracle(abi.encode(rejected));
        assertEq(oracle.cutoff(), 10_292);
        assertEq(_batch(false).allocation, 200);
        // Transactions later in the acceptance block still belong to currentBatch.
        _allocate(100);
        delegator.requestDeallocate(address(adapter), 500);
        assertEq(adapter.deallocatable(), 300);
        assertEq(_batch(false).deallocation, 200);
        vm.warp(10_292);
        vm.roll(block.number + 1);
        _allocate(50);
        assertEq(_batch(true).allocation, 50);
        vm.warp(10_300);
        vm.roll(block.number + 1);
        _deliver(_report(3000)); // 3350 gross - 300 reserves - 50 next-batch allocation.
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 4);
        assertEq(oracle.totalAssets(), 2800);
        assertEq(adapter.deallocatable(), 500);
        assertEq(_batch(false).allocation, 50);
        assertEq(
            oracle.totalAssets() + adapter.deallocatable() + _batch(false).allocation,
            asset.balanceOf(account) + asset.balanceOf(address(adapter))
        );
        assertEq(oracle.cutoff(), 10_390);
    }

    function testFuzz_ProposedCutoffStillRejectsPreReviewSnapshot(uint8 offset) public {
        offset = uint8(bound(offset, 90, 98));
        ICREOracle.Report memory rejected = _freezeFundedPortfolio();
        vm.warp(10_200 + offset);
        vm.roll(block.number + 1);
        oracle.unfreezeOracle(abi.encode(rejected));
        assertEq(oracle.cutoff(), block.timestamp + 1);
        ICREOracle.Report memory stale = _report(3200);
        vm.warp(10_300);
        vm.roll(block.number + 1);
        _expectReportError(stale, ICREOracle.StaleReport.selector);
        _deliver(_report(3200));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 4);
        assertEq(oracle.totalAssets(), 3200);
    }

    function _upsert(bytes32 id) internal {
        vm.prank(address(workflowRegistry));
        IChainlinkWorkflowRegistry(address(chainlinkRegistry))
            .upsertWorkflow(
                Strings.toHexString(address(oracle)),
                "default",
                id,
                IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE,
                DON_FAMILY,
                "https://example.com/new.wasm.br",
                "",
                "",
                false
            );
    }

    function test_UpstreamSupportsNormalInPlaceRotation() public {
        uint64 created = chainlinkRegistry.getWorkflowById(WORKFLOW).createdAt;
        vm.warp(block.timestamp + 1);
        _upsert(NEXT);
        assertEq(chainlinkRegistry.getWorkflowById(NEXT).createdAt, created);
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(0));
        assertEq(chainlinkRegistry.totalActiveWorkflowsByOwner(address(workflowRegistry)), 1);
    }

    function test_UpstreamInPlaceRotationSurvivesQuotaReduction() public {
        chainlinkRegistry.setDONLimit(DON_FAMILY, 100, 0);
        _proposeWorkflow(address(oracle), NEXT);
        vm.expectRevert();
        _acceptWorkflow(address(oracle), NEXT);
        assertEq(workflowRegistry.workflowIds(address(oracle)), WORKFLOW);
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(workflowRegistry));
        _upsert(NEXT);
        assertEq(chainlinkRegistry.getWorkflowById(NEXT).owner, address(workflowRegistry));
    }

    function test_UpstreamInPlaceRotationCannotReactivatePausedWorkflow() public {
        chainlinkRegistry.adminPauseWorkflow(WORKFLOW);
        vm.expectRevert();
        _upsert(NEXT);
        _proposeWorkflow(address(oracle), NEXT);
        _acceptWorkflow(address(oracle), NEXT);
        assertEq(chainlinkRegistry.totalActiveWorkflowsByOwner(address(workflowRegistry)), 1);
    }

    function test_UpstreamInPlaceRotationCannotReuseExistingID() public {
        vm.expectRevert(abi.encodeWithSignature("WorkflowIDAlreadyExists(bytes32)", WORKFLOW));
        _upsert(WORKFLOW);
        _proposeWorkflow(address(oracle), WORKFLOW);
        _acceptWorkflow(address(oracle), WORKFLOW);
        assertEq(chainlinkRegistry.totalActiveWorkflowsByOwner(address(workflowRegistry)), 1);
    }
}
