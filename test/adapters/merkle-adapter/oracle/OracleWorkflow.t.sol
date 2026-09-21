// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {Oracle} from "src/contracts/merkle-adapter/oracle/Oracle.sol";

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IOracle} from "src/interfaces/merkle-adapter/oracle/IOracle.sol";

import {OracleTestBase} from "test/adapters/merkle-adapter/oracle/Oracle.t.sol";

contract OracleWorkflowTest is OracleTestBase {
    bytes32 constant NEXT_WORKFLOW = keccak256("reviewed next NAV workflow");

    /// forge-config: default.isolate = true
    function test_ProposalRequiresProviderAndAcceptanceRequiresCurator() public {
        address curator = makeAddr("curator");
        MerkleAccount(payable(account)).transferOwnership(curator);
        vm.prank(curator);
        vm.expectRevert(IOracle.InvalidCaller.selector);
        oracle.proposeWorkflow(NEXT_WORKFLOW);
        vm.expectEmit(address(oracle));
        emit IOracle.ProposeWorkflow(NEXT_WORKFLOW);
        oracle.proposeWorkflow(NEXT_WORKFLOW);
        vm.snapshotGasLastCall("OracleWorkflow", "proposeWorkflow");
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(oracle.proposedWorkflowId(), NEXT_WORKFLOW);
        vm.expectRevert(IOracle.InvalidCaller.selector);
        oracle.acceptWorkflow(NEXT_WORKFLOW);
        vm.expectEmit(address(oracle));
        emit IOracle.AcceptWorkflow(NEXT_WORKFLOW);
        vm.prank(curator);
        oracle.acceptWorkflow(NEXT_WORKFLOW);
        vm.snapshotGasLastCall("OracleWorkflow", "acceptWorkflow");
        assertEq(oracle.workflowId(), NEXT_WORKFLOW);
        assertEq(oracle.proposedWorkflowId(), bytes32(0));
        assertEq(oracle.version(), 1);
    }

    function testFuzz_CannotAcceptAnotherId(bytes32 otherId) public {
        vm.assume(otherId != NEXT_WORKFLOW);
        oracle.proposeWorkflow(NEXT_WORKFLOW);
        vm.expectRevert(IOracle.InvalidWorkflow.selector);
        oracle.acceptWorkflow(otherId);
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(oracle.proposedWorkflowId(), NEXT_WORKFLOW);
    }

    function test_ReplacedCancelledAndConsumedProposalsCannotBeAccepted() public {
        oracle.proposeWorkflow(NEXT_WORKFLOW);
        oracle.proposeWorkflow(keccak256("replacement"));
        vm.expectRevert(IOracle.InvalidWorkflow.selector);
        oracle.acceptWorkflow(NEXT_WORKFLOW);
        oracle.proposeWorkflow(bytes32(0));
        vm.expectRevert(IOracle.InvalidWorkflow.selector);
        oracle.acceptWorkflow(bytes32(0));
        vm.expectRevert(IOracle.InvalidWorkflow.selector);
        oracle.acceptWorkflow(keccak256("replacement"));
        assertEq(oracle.workflowId(), WORKFLOW);
        _deliver(_report(0));
        oracle.proposeWorkflow(NEXT_WORKFLOW);
        oracle.acceptWorkflow(NEXT_WORKFLOW);
        vm.expectRevert(IOracle.InvalidWorkflow.selector);
        oracle.acceptWorkflow(NEXT_WORKFLOW);
    }

    function test_ChangedFactoryOwnerControlsFutureProposals() public {
        address provider = makeAddr("newProvider");
        factory.transferOwnership(provider);
        vm.expectRevert(IOracle.InvalidCaller.selector);
        oracle.proposeWorkflow(NEXT_WORKFLOW);
        vm.prank(provider);
        oracle.proposeWorkflow(NEXT_WORKFLOW);
        oracle.acceptWorkflow(NEXT_WORKFLOW);
        assertEq(oracle.workflowId(), NEXT_WORKFLOW);
    }

    function test_AcceptanceUsesCurrentAdapterOwnerNotStaleOracleOwner() public {
        address curator = makeAddr("newCurator");
        MerkleAccount(payable(account)).transferOwnership(curator);
        assertEq(oracle.owner(), address(this));
        oracle.proposeWorkflow(NEXT_WORKFLOW);
        vm.expectRevert(IOracle.InvalidCaller.selector);
        oracle.acceptWorkflow(NEXT_WORKFLOW);
        vm.prank(curator);
        oracle.acceptWorkflow(NEXT_WORKFLOW);
        assertEq(oracle.workflowId(), NEXT_WORKFLOW);
    }

    function test_WorkflowChangePreservesFreezeAndDiscardsRejectedReport() public {
        _deliverWithReview(_report(100));
        _advanceReport();
        _deliver(_report(300));
        assertTrue(oracle.oracleFrozen());
        assertTrue(oracle.rejectedReportHash() != bytes32(0));
        oracle.proposeWorkflow(NEXT_WORKFLOW);
        oracle.acceptWorkflow(NEXT_WORKFLOW);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        oracle.freezeOracle();
        oracle.proposeWorkflow(WORKFLOW);
        oracle.acceptWorkflow(WORKFLOW);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 100);
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(oracle.snapshotTimestamp(), 9999);
        vm.expectRevert(IOracle.OracleFrozen.selector);
        adapter.totalAssets();
        _advanceReport();
        _deliver(_report(100));
        assertEq(oracle.nonce(), 1);
    }

    function test_WorkflowChangeDoesNotRefreshExpiredNAV() public {
        _deliver(_report(0));
        vm.warp(oracle.snapshotTimestamp() + 1 days + 1);
        oracle.proposeWorkflow(NEXT_WORKFLOW);
        oracle.acceptWorkflow(NEXT_WORKFLOW);
        vm.expectRevert(IOracle.OracleStale.selector);
        oracle.validate();
    }

    function test_NewWorkflowContinuesEpochAndOldWorkflowIsRejectedByRealForwarder() public {
        _deliverWithReview(_report(100));
        oracle.proposeWorkflow(NEXT_WORKFLOW);
        _advanceReport();
        IOracle.Report memory update = _report(105);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, NEXT_WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertFalse(forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(2)), bytes2(0)).success);
        assertEq(oracle.nonce(), 1);
        oracle.acceptWorkflow(NEXT_WORKFLOW);
        (raw, signatures) = _signedReport(update, WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertFalse(forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(2)), bytes2(0)).success);
        assertEq(oracle.nonce(), 1);
        (raw, signatures) = _signedReport(update, NEXT_WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertTrue(forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(2)), bytes2(0)).success);
        assertEq(oracle.nonce(), 2);
        assertEq(oracle.totalAssets(), 105);
        assertEq(oracle.version(), 1);
    }

    function test_TwoCuratorsAcceptSeparateWorkflowsOnSharedImplementation() public {
        address curatorA = makeAddr("curatorA");
        address curatorB = makeAddr("curatorB");
        MerkleAccount(payable(account)).transferOwnership(curatorA);
        address adapterB = AdapterFactory(adapter.FACTORY())
            .create(
                1,
                curatorB,
                abi.encode(adapter.vault(), abi.encode(IMerkleAdapter.InitParams({defaultAdminRoleHolder: curatorB})))
            );
        address receiverB = MerkleAdapter(payable(adapterB)).oracle();
        Oracle(receiverB).proposeWorkflow(NEXT_WORKFLOW);
        vm.prank(curatorA);
        vm.expectRevert(IOracle.InvalidCaller.selector);
        Oracle(receiverB).acceptWorkflow(NEXT_WORKFLOW);
        vm.prank(curatorB);
        vm.expectRevert(IOracle.InvalidCaller.selector);
        oracle.acceptWorkflow(WORKFLOW);
        vm.prank(curatorB);
        Oracle(receiverB).acceptWorkflow(NEXT_WORKFLOW);
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(Oracle(receiverB).workflowId(), NEXT_WORKFLOW);
        assertEq(oracle.version(), Oracle(receiverB).version());
        _deliver(_report(0));
        IOracle.Report memory update = IOracle.Report({
            chainId: block.chainid,
            oracle: receiverB,
            adapter: adapterB,
            nonce: 1,
            totalAssets: 0,
            snapshotBlock: block.number - 1,
            snapshotTimestamp: block.timestamp - 1
        });
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, WORKFLOW);
        forwarder.report(receiverB, raw, bytes(""), signatures);
        assertEq(Oracle(receiverB).nonce(), 0);
        (raw, signatures) = _signedReport(update, NEXT_WORKFLOW);
        forwarder.report(receiverB, raw, bytes(""), signatures);
        assertEq(Oracle(receiverB).nonce(), 1);
        oracle.proposeWorkflow(keccak256("curator A's next version"));
        vm.prank(curatorA);
        oracle.acceptWorkflow(keccak256("curator A's next version"));
        assertEq(Oracle(receiverB).workflowId(), NEXT_WORKFLOW);
        assertEq(Oracle(receiverB).nonce(), 1);
        assertEq(Oracle(receiverB).snapshotTimestamp(), 9999);
        _advanceReport();
        update.nonce = 2;
        update.snapshotBlock++;
        update.snapshotTimestamp = block.timestamp - 1;
        (raw, signatures) = _signedReport(update, NEXT_WORKFLOW);
        forwarder.report(receiverB, raw, bytes(""), signatures);
        assertEq(Oracle(receiverB).nonce(), 2);
    }
}
