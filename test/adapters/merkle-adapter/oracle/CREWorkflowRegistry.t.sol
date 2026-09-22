// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {ICREOracle, ORACLE_GUARD_ROLE} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";
import {IWorkflowRegistry as WorkflowRegistry} from "test/mocks/chainlink-cre/interfaces/IWorkflowRegistry.sol";
import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";

contract CREWorkflowRegistryTest is CREOracleTestBase {
    bytes32 constant NEXT_WORKFLOW = keccak256("next NAV workflow");

    function testFuzz_OwnerRotationsPreserveSymbioticProposalAndCuratorAcceptance(address provider) public {
        address curator = makeAddr("curator");
        address newCurator = makeAddr("new curator");
        vm.assume(provider != address(0) && provider != address(this) && provider != curator && provider != newCurator);
        oracle.transferOwnership(curator);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        bytes32 proposedDataHash = workflowRegistry.proposals(address(oracle));

        workflowRegistry.transferOwnership(provider);
        assertEq(workflowRegistry.owner(), provider);
        assertTrue(workflowRegistry.initialized());
        _assertUnchangedProposal();
        bytes32 retainedDataHash = workflowRegistry.proposals(address(oracle));
        assertEq(retainedDataHash, proposedDataHash);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        _proposeWorkflow(address(oracle), bytes32(0));

        vm.prank(curator);
        oracle.transferOwnership(newCurator);
        assertEq(oracle.owner(), newCurator);
        vm.prank(curator);
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.prank(newCurator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newCurator));
        _proposeWorkflow(address(oracle), bytes32(0));
        _assertUnchangedProposal();

        vm.startPrank(provider);
        _proposeWorkflow(address(oracle), bytes32(0));
        assertEq(workflowRegistry.proposals(address(oracle)), _proposalHash(bytes32(0)));
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(ICREWorkflowRegistry.AlreadyInitialized.selector);
        workflowRegistry.linkOwner(block.timestamp + 1 hours, bytes32(0), "");
        vm.stopPrank();
        _assertUnchangedProposal();

        vm.prank(newCurator);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
    }

    function test_RenouncingOwnershipPreservesWorkflowAndPendingCuratorAcceptance() public {
        address curator = makeAddr("curator");
        oracle.transferOwnership(curator);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        workflowRegistry.renounceOwnership();
        assertEq(workflowRegistry.owner(), address(0));
        assertTrue(workflowRegistry.initialized());
        _assertUnchangedProposal();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        _proposeWorkflow(address(oracle), bytes32(0));
        vm.prank(curator);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
    }

    function test_OwnerCannotRelinkAfterAcceptance() public {
        assertTrue(workflowRegistry.initialized());
        bytes4 errorSelector = ICREWorkflowRegistry.AlreadyInitialized.selector;
        vm.expectRevert(errorSelector);
        workflowRegistry.linkOwner(block.timestamp + 1 hours, bytes32(0), "");
        assertEq(workflowRegistry.owner(), address(this));
        _assertRegistration(address(oracle), WORKFLOW);
    }

    function test_OnlyProviderProposesAndCurrentOracleOwnerAccepts() public {
        address curator = makeAddr("curator");
        oracle.transferOwnership(curator);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, curator));
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.snapshotGasLastCall("CREWorkflowRegistry", "proposeWorkflow");
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(workflowRegistry.proposals(address(oracle)), _proposalHash(NEXT_WORKFLOW));
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.prank(curator);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.snapshotGasLastCall("CREWorkflowRegistry", "acceptWorkflow");
        assertEq(oracle.workflowId(), NEXT_WORKFLOW);
        assertEq(workflowRegistry.proposals(address(oracle)), _proposalHash(bytes32(0)));
        assertEq(oracle.version(), 1);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(0));
    }

    function testFuzz_CannotAcceptAnotherId(bytes32 otherId) public {
        vm.assume(otherId != NEXT_WORKFLOW);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(ICREWorkflowRegistry.InvalidWorkflow.selector);
        _acceptWorkflow(address(oracle), otherId);
        _assertUnchangedProposal();
    }

    function testFuzz_ChangedRegistrationDataCannotBeAccepted(uint8 field) public {
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        field = uint8(bound(field, 0, 3));
        if (field == 0) params.donFamily = "other-don";
        else if (field == 1) params.binaryUrl = "https://example.com/other.wasm.br";
        else if (field == 2) params.configUrl = "https://example.com/other.json";
        else params.attributes = hex"03";
        vm.expectRevert(ICREWorkflowRegistry.InvalidWorkflow.selector);
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        _assertUnchangedProposal();
    }

    function test_ReplacedCancelledAndConsumedProposalsCannotBeAccepted() public {
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _proposeWorkflow(address(oracle), keccak256("replacement"));
        vm.expectRevert(ICREWorkflowRegistry.InvalidWorkflow.selector);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _proposeWorkflow(address(oracle), bytes32(0));
        assertEq(workflowRegistry.proposals(address(oracle)), bytes32(0));
        vm.expectRevert(ICREWorkflowRegistry.InvalidWorkflow.selector);
        _acceptWorkflow(address(oracle), bytes32(0));
        vm.expectRevert(ICREWorkflowRegistry.InvalidWorkflow.selector);
        _acceptWorkflow(address(oracle), keccak256("replacement"));
        _assertRegistration(address(oracle), WORKFLOW);
        _deliver(_report(0));
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(ICREWorkflowRegistry.InvalidWorkflow.selector);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
    }

    function test_OnlyOracleOwnershipControlsAcceptanceAfterTransfers() public {
        address accountOwner = makeAddr("account owner");
        address oracleOwner = makeAddr("oracle owner");
        MerkleAccount(payable(account)).transferOwnership(accountOwner);
        adapter.transferOwnership(accountOwner);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.prank(accountOwner);
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        oracle.transferOwnership(oracleOwner);
        assertTrue(oracle.hasRole(bytes32(0), address(this)));
        assertTrue(oracle.hasRole(ORACLE_GUARD_ROLE, address(this)));
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.prank(oracleOwner);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
    }

    function test_RegistrationFailureRollsBackDeletedWorkflowAndReceiverState() public {
        _deliverWithReview(_report(100));
        _advanceReport();
        _deliver(_report(300));
        bytes32 rejected = oracle.rejectedReportHash();
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.binaryUrl = "";
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.expectRevert(WorkflowRegistry.BinaryURLRequired.selector);
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        _assertUnchangedProposal(keccak256(abi.encode(NEXT_WORKFLOW, params)));
        assertEq(oracle.rejectedReportHash(), rejected);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 100);
        assertEq(oracle.nonce(), 1);
    }

    function test_UnknownDONRollsBackReplacement() public {
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.donFamily = "unknown-don";
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.expectRevert(abi.encodeWithSelector(WorkflowRegistry.DonLimitNotSet.selector, params.donFamily));
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        _assertUnchangedProposal(keccak256(abi.encode(NEXT_WORKFLOW, params)));
    }

    function test_ReplacementCanChangeDONAndRecoverPausedWorkflow() public {
        chainlinkRegistry.adminPauseWorkflow(WORKFLOW);
        chainlinkRegistry.setDONLimit("new-don", 1, 1);
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.donFamily = "new-don";
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        WorkflowRegistry.WorkflowMetadataView memory rec = chainlinkRegistry.getWorkflowById(NEXT_WORKFLOW);
        assertEq(rec.donFamily, "new-don");
        assertEq(uint256(rec.status), uint256(WorkflowRegistry.WorkflowStatus.ACTIVE));
        assertEq(chainlinkRegistry.totalActiveWorkflowsOnDON(DON_FAMILY), 0);
        assertEq(chainlinkRegistry.totalActiveWorkflowsOnDON("new-don"), 1);
    }

    function test_ChainlinkUnlinkingCannotAllowRelinking() public {
        uint256 expiry = block.timestamp + 1 days;
        chainlinkRegistry.unlinkOwner(
            address(workflowRegistry), expiry, _linkSignature(1, expiry, keccak256("test ownership proof"))
        );
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(
            abi.encodeWithSelector(WorkflowRegistry.OwnershipLinkDoesNotExist.selector, address(workflowRegistry))
        );
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(workflowRegistry.proposals(address(oracle)), _proposalHash(NEXT_WORKFLOW));
        uint256 newExpiry = block.timestamp + 1 days;
        bytes32 newProof = keccak256("replacement test ownership proof");
        bytes memory signature = _linkSignature(0, newExpiry, newProof);
        vm.expectRevert(ICREWorkflowRegistry.AlreadyInitialized.selector);
        workflowRegistry.linkOwner(newExpiry, newProof, signature);
        assertTrue(workflowRegistry.initialized());
        assertFalse(chainlinkRegistry.isOwnerLinked(address(workflowRegistry)));
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(0));
    }

    function test_DirectReceiverUpdateAndWrongRegistryAreRejected() public {
        vm.expectRevert(ICREOracle.InvalidCaller.selector);
        oracle.setWorkflowId(NEXT_WORKFLOW);
        CREWorkflowRegistry other = new CREWorkflowRegistry(address(this), address(chainlinkRegistry));
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        vm.expectRevert(ICREWorkflowRegistry.InvalidOracle.selector);
        other.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.expectRevert(ICREWorkflowRegistry.InvalidOracle.selector);
        other.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
    }

    function test_WorkflowChangePreservesAccountingAndFreezeAndDiscardsRejectedReport() public {
        _deliverWithReview(_report(100));
        _advanceReport();
        ICREOracle.Report memory rejected = _report(300);
        _deliver(rejected);
        uint256 previousCutoff = oracle.cutoff();
        assertTrue(oracle.oracleFrozen());
        assertTrue(oracle.rejectedReportHash() != bytes32(0));
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 100);
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(oracle.snapshotTimestamp(), 9999);
        assertEq(oracle.cutoff(), previousCutoff);
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        adapter.totalAssets();
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(abi.encode(rejected));
    }

    function test_WorkflowChangeDoesNotRefreshExpiredNAV() public {
        _deliver(_report(0));
        vm.warp(oracle.snapshotTimestamp() + 1 days + 1);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(ICREOracle.OracleStale.selector);
        oracle.validate();
    }

    function test_NewWorkflowContinuesEpochAndOldWorkflowIsRejectedByRealForwarder() public {
        _deliverWithReview(_report(100));
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _advanceReport();
        ICREOracle.Report memory update = _report(105);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, NEXT_WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertFalse(forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(2)), bytes2(0)).success);
        assertEq(oracle.nonce(), 1);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        (raw, signatures) = _signedReport(update, WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertFalse(forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(2)), bytes2(0)).success);
        assertEq(oracle.nonce(), 1);
        (raw, signatures) = _signedReport(update, NEXT_WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertTrue(forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(2)), bytes2(0)).success);
        assertEq(oracle.nonce(), 2);
        assertEq(oracle.totalAssets(), 105);
    }

    function test_TwoOraclesHaveIsolatedRegistrationsAndDuplicateIdRollsBack() public {
        address curatorB = makeAddr("curator B");
        address adapterB = AdapterFactory(adapter.FACTORY())
            .create(1, curatorB, abi.encode(adapter.vault(), abi.encode(merkleAdapterInitParams(curatorB))));
        address receiverB = MerkleAdapter(payable(adapterB)).oracle();
        _proposeWorkflow(receiverB, NEXT_WORKFLOW);
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        _acceptWorkflow(receiverB, NEXT_WORKFLOW);
        vm.prank(curatorB);
        _acceptWorkflow(receiverB, NEXT_WORKFLOW);
        _assertRegistration(receiverB, NEXT_WORKFLOW);
        _assertRegistration(address(oracle), WORKFLOW);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(abi.encodeWithSelector(WorkflowRegistry.WorkflowIDAlreadyExists.selector, NEXT_WORKFLOW));
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertUnchangedProposal();
        _proposeWorkflow(address(oracle), keccak256("A v2"));
        _acceptWorkflow(address(oracle), keccak256("A v2"));
        _assertRegistration(receiverB, NEXT_WORKFLOW);
        _assertRegistration(address(oracle), keccak256("A v2"));
        assertEq(chainlinkRegistry.totalActiveWorkflowsByOwner(address(workflowRegistry)), 2);
        ICREOracle.Report memory update = ICREOracle.Report({
            chainId: block.chainid,
            oracle: receiverB,
            adapter: adapterB,
            nonce: 1,
            totalAssets: 0,
            snapshotBlock: block.number - 1,
            snapshotTimestamp: block.timestamp - 1
        });
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, WORKFLOW);
        forwarder.report(receiverB, raw, "", signatures);
        assertEq(CREOracle(receiverB).nonce(), 0);
        (raw, signatures) = _signedReport(update, NEXT_WORKFLOW);
        forwarder.report(receiverB, raw, "", signatures);
        assertEq(CREOracle(receiverB).nonce(), 1);
    }

    function test_ReceiverCallbackFailureRollsBackChainlinkRegistration() public {
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        bytes memory failure = abi.encodeWithSignature("ReceiverFailure()");
        vm.mockCallRevert(address(oracle), abi.encodeCall(ICREOracle.setWorkflowId, (NEXT_WORKFLOW)), failure);
        vm.expectRevert(failure);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.clearMockedCalls();
        _assertUnchangedProposal();
        assertEq(chainlinkRegistry.getWorkflowById(NEXT_WORKFLOW).owner, address(0));
    }

    function test_ReceiverCannotClaimAnotherOraclesPreviousRegistration() public {
        address adapterB = AdapterFactory(adapter.FACTORY())
            .create(1, address(this), abi.encode(adapter.vault(), abi.encode(merkleAdapterInitParams(address(this)))));
        address receiverB = MerkleAdapter(payable(adapterB)).oracle();
        _proposeWorkflow(receiverB, NEXT_WORKFLOW);
        _acceptWorkflow(receiverB, NEXT_WORKFLOW);
        // A changed receiver implementation can return any ID. The immutable registry owns the authoritative record.
        vm.mockCall(address(oracle), abi.encodeCall(ICREOracle.workflowId, ()), abi.encode(NEXT_WORKFLOW));
        bytes32 replacement = keccak256("A v2");
        _proposeWorkflow(address(oracle), replacement);
        _acceptWorkflow(address(oracle), replacement);
        vm.clearMockedCalls();
        _assertRegistration(address(oracle), replacement);
        _assertRegistration(receiverB, NEXT_WORKFLOW);
    }

    function _assertUnchangedProposal() internal view {
        _assertUnchangedProposal(_proposalHash(NEXT_WORKFLOW));
    }

    function _assertUnchangedProposal(bytes32 expectedProposal) internal view {
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(workflowRegistry.proposals(address(oracle)), expectedProposal);
        _assertRegistration(address(oracle), WORKFLOW);
    }

    function _assertRegistration(address receiver, bytes32 id) internal view {
        WorkflowRegistry.WorkflowMetadataView memory rec = chainlinkRegistry.getWorkflowById(id);
        assertEq(rec.workflowId, id);
        assertEq(rec.owner, address(workflowRegistry));
        assertEq(rec.workflowName, Strings.toHexString(receiver));
        assertEq(rec.tag, "default");
        assertEq(rec.donFamily, DON_FAMILY);
        assertEq(uint256(rec.status), uint256(WorkflowRegistry.WorkflowStatus.ACTIVE));
        assertEq(rec.binaryUrl, _workflowParams().binaryUrl);
        assertEq(rec.configUrl, _workflowParams().configUrl);
        assertEq(rec.attributes, _workflowParams().attributes);
        assertEq(workflowRegistry.workflowIds(receiver), id);
        assertEq(CREOracle(receiver).workflowId(), id);
    }
}
