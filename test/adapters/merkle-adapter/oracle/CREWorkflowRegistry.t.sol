// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {ICREOracle, ORACLE_GUARD_ROLE} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IChainlinkWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/IChainlinkWorkflowRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";
import {encodeWorkflowName} from "test/helpers/CREWorkflowName.sol";
import {IWorkflowRegistry as WorkflowRegistry} from "test/mocks/chainlink-cre/interfaces/IWorkflowRegistry.sol";
import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";

contract CREWorkflowRegistryTest is CREOracleTestBase {
    bytes32 constant NEXT_WORKFLOW = keccak256("next NAV workflow");

    function test_NormalRotationUpdatesTheExistingRecordWithoutDeletion() public {
        uint64 createdAt = chainlinkRegistry.getWorkflowById(WORKFLOW).createdAt;
        vm.warp(block.timestamp + 1);
        vm.mockCallRevert(
            address(chainlinkRegistry),
            abi.encodeCall(IChainlinkWorkflowRegistry.deleteWorkflow, (WORKFLOW)),
            abi.encodeWithSignature("UnexpectedDeletionFailure()")
        );
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
        assertEq(chainlinkRegistry.getWorkflowById(NEXT_WORKFLOW).createdAt, createdAt);
        assertEq(chainlinkRegistry.totalActiveWorkflowsByOwner(address(workflowRegistry)), 1);
    }

    function test_NormalRotationRemainsAvailableAfterQuotaReduction() public {
        chainlinkRegistry.setDONLimit(DON_FAMILY, 100, 0);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
    }

    function test_ReusedIdCannotAffectAnotherOracleOnRotation() public {
        vm.prank(address(workflowRegistry));
        IChainlinkWorkflowRegistry(address(chainlinkRegistry)).deleteWorkflow(WORKFLOW);
        address otherCurator = makeAddr("independent curator");
        address receiverB = _newOracle(otherCurator);
        _proposeWorkflow(receiverB, WORKFLOW);
        vm.prank(otherCurator);
        _acceptWorkflow(receiverB, WORKFLOW);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
        _assertRegistration(receiverB, WORKFLOW);
    }

    function testFuzz_OwnerRotationsPreserveSymbioticProposalAndCuratorAcceptance(address provider) public {
        address curator = makeAddr("curator");
        address newCurator = makeAddr("new curator");
        vm.assume(provider != address(0) && provider != address(this) && provider != curator && provider != newCurator);
        oracle.transferOwnership(curator);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);

        workflowRegistry.transferOwnership(provider);
        assertEq(workflowRegistry.owner(), provider);
        _assertUnchangedProposal();
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
        _assertProposal(address(oracle), bytes32(0));
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(abi.encodeWithSignature("OwnershipLinkAlreadyExists(address)", address(workflowRegistry)));
        workflowRegistry.linkOwner(SafeCast.toUint48(block.timestamp + 1 hours), bytes32(0), "");
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
        _assertUnchangedProposal();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        _proposeWorkflow(address(oracle), bytes32(0));
        vm.prank(curator);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
    }

    function test_OwnerCannotRelinkAfterAcceptance() public {
        vm.expectRevert(abi.encodeWithSignature("OwnershipLinkAlreadyExists(address)", address(workflowRegistry)));
        workflowRegistry.linkOwner(SafeCast.toUint48(block.timestamp + 1 hours), bytes32(0), "");
        assertEq(workflowRegistry.owner(), address(this));
        _assertRegistration(address(oracle), WORKFLOW);
    }

    /// forge-config: default.isolate = true
    function test_OnlyProviderProposesAndCurrentOracleOwnerAccepts() public {
        address curator = makeAddr("curator");
        oracle.transferOwnership(curator);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, curator));
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.snapshotGasLastCall("CREWorkflowRegistry", "proposeWorkflow");
        assertEq(workflowRegistry.workflowId(address(oracle)), WORKFLOW);
        _assertProposal(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.prank(curator);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.snapshotGasLastCall("CREWorkflowRegistry", "acceptWorkflow");
        assertEq(workflowRegistry.workflowId(address(oracle)), NEXT_WORKFLOW);
        _assertProposal(address(oracle), bytes32(0));
        assertEq(oracle.version(), 1);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(0));
    }

    /// forge-config: default.isolate = true
    function test_GasProposalReplacementCancellationAndReads() public {
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.binaryUrl = "https://example.com/replacement.wasm.br";
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.snapshotGasLastCall("CREWorkflowRegistry", "proposeWorkflowReplace");
        (
            string memory tag,
            IChainlinkWorkflowRegistry.WorkflowStatus status,
            string memory donFamily,
            string memory binaryUrl,
            string memory configUrl,
            bytes memory attributes
        ) = workflowRegistry.proposedWorkflowParams(address(oracle));
        vm.snapshotGasLastCall("CREWorkflowRegistry", "proposedWorkflowParamsConfigured");
        assertEq(tag, params.tag);
        assertEq(uint256(status), uint256(params.status));
        assertEq(donFamily, params.donFamily);
        assertEq(binaryUrl, params.binaryUrl);
        assertEq(configUrl, params.configUrl);
        assertEq(attributes, params.attributes);

        _proposeWorkflow(address(oracle), bytes32(0));
        vm.snapshotGasLastCall("CREWorkflowRegistry", "proposeWorkflowCancel");
        (tag, status, donFamily, binaryUrl, configUrl, attributes) =
            workflowRegistry.proposedWorkflowParams(address(oracle));
        vm.snapshotGasLastCall("CREWorkflowRegistry", "proposedWorkflowParamsEmpty");
        assertEq(tag, "");
        assertEq(uint256(status), uint256(IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE));
        assertEq(donFamily, "");
        assertEq(binaryUrl, "");
        assertEq(configUrl, "");
        assertEq(attributes.length, 0);
        assertEq(workflowRegistry.proposedWorkflowId(address(oracle)), bytes32(0));
        assertEq(workflowRegistry.workflowId(address(oracle)), WORKFLOW);
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
        field = uint8(bound(field, 0, 5));
        if (field == 0) params.tag = "other-tag";
        else if (field == 1) params.donFamily = "other-don";
        else if (field == 2) params.binaryUrl = "https://example.com/other.wasm.br";
        else if (field == 3) params.configUrl = "https://example.com/other.json";
        else if (field == 4) params.attributes = hex"03";
        else params.status = IChainlinkWorkflowRegistry.WorkflowStatus.PAUSED;
        vm.expectRevert(ICREWorkflowRegistry.InvalidWorkflow.selector);
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        _assertUnchangedProposal();

        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.expectRevert(ICREWorkflowRegistry.InvalidWorkflow.selector);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertUnchangedProposal(NEXT_WORKFLOW, params);
    }

    function testFuzz_ProposalReplacementAndCancellationClearPreviousData(
        string memory tag,
        bool paused,
        string memory donFamily,
        string memory binaryUrl,
        string memory configUrl,
        bytes memory attributes
    ) public {
        ICREWorkflowRegistry.WorkflowParams memory params = ICREWorkflowRegistry.WorkflowParams({
            tag: tag,
            status: paused
                ? IChainlinkWorkflowRegistry.WorkflowStatus.PAUSED
                : IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE,
            donFamily: donFamily,
            binaryUrl: binaryUrl,
            configUrl: configUrl,
            attributes: attributes
        });
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        _assertProposal(address(oracle), NEXT_WORKFLOW, params);
        _proposeWorkflow(address(oracle), keccak256("replacement"));
        _assertProposal(address(oracle), keccak256("replacement"));
        _proposeWorkflow(address(oracle), bytes32(0));
        _assertProposal(address(oracle), bytes32(0));
        _assertRegistration(address(oracle), WORKFLOW);
    }

    function test_CancellationEmitsClearedParameters() public {
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        ICREWorkflowRegistry.WorkflowParams memory cleared;
        vm.expectEmit(true, true, false, true, address(workflowRegistry));
        emit ICREWorkflowRegistry.ProposeWorkflow(address(oracle), bytes32(0), cleared);
        workflowRegistry.proposeWorkflow(address(oracle), bytes32(0), params);
        _assertProposal(address(oracle), bytes32(0));
        _assertRegistration(address(oracle), WORKFLOW);
    }

    function test_AcceptanceUsesExactStoredParametersAndClearsProposal() public {
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.binaryUrl = "https://example.com/replacement.wasm.br";
        params.configUrl = "";
        params.attributes = hex"030405";
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        _assertProposal(address(oracle), NEXT_WORKFLOW, params);

        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);

        _assertProposal(address(oracle), bytes32(0));
        WorkflowRegistry.WorkflowMetadataView memory record = chainlinkRegistry.getWorkflowById(NEXT_WORKFLOW);
        assertEq(record.donFamily, params.donFamily);
        assertEq(record.binaryUrl, params.binaryUrl);
        assertEq(record.configUrl, params.configUrl);
        assertEq(record.attributes, params.attributes);
        assertEq(workflowRegistry.workflowId(address(oracle)), NEXT_WORKFLOW);
    }

    /// forge-config: default.isolate = true
    function test_ReplacedCancelledAndConsumedProposalsCannotBeAccepted() public {
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _proposeWorkflow(address(oracle), keccak256("replacement"));
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        vm.expectRevert(ICREWorkflowRegistry.InvalidWorkflow.selector);
        vm.startSnapshotGas("CREWorkflowRegistry", "acceptWorkflowMismatchRegion");
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.stopSnapshotGas();
        _proposeWorkflow(address(oracle), bytes32(0));
        _assertProposal(address(oracle), bytes32(0));
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

    function test_RegistrationFailurePreservesWorkflowAndReceiverState() public {
        _deliverWithReview(_report(100));
        _advanceReport();
        _deliver(_report(300));
        bytes32 rejected = oracle.rejectedReportHash();
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.binaryUrl = "";
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.expectRevert(WorkflowRegistry.BinaryURLRequired.selector);
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        _assertUnchangedProposal(NEXT_WORKFLOW, params);
        assertEq(oracle.rejectedReportHash(), rejected);
        assertEq(adapter.totalAssets(), 100);
        assertEq(_acceptedSnapshotBlock(), 499);
    }

    function test_DONChangeCannotBeAccepted() public {
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.donFamily = "unknown-don";
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.expectRevert(
            abi.encodeWithSignature(
                "CannotChangeDONFamilyOnUpdate(bytes32,address,string,string,string)",
                NEXT_WORKFLOW,
                address(workflowRegistry),
                Strings.toHexString(address(oracle)),
                "default",
                params.donFamily
            )
        );
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        _assertUnchangedProposal(NEXT_WORKFLOW, params);
    }

    /// forge-config: default.isolate = true
    function test_NewTagCanCreatePausedReplacement() public {
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.tag = "paused-replacement";
        params.status = IChainlinkWorkflowRegistry.WorkflowStatus.PAUSED;
        chainlinkRegistry.setDONLimit(DON_FAMILY, 0, 0);
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.snapshotGasLastCall("CREWorkflowRegistry", "acceptWorkflowPaused");
        WorkflowRegistry.WorkflowMetadataView memory rec = chainlinkRegistry.getWorkflowById(NEXT_WORKFLOW);
        assertEq(rec.workflowId, NEXT_WORKFLOW);
        assertEq(rec.tag, params.tag);
        assertEq(uint256(rec.status), uint256(WorkflowRegistry.WorkflowStatus.PAUSED));
        assertEq(
            uint256(chainlinkRegistry.getWorkflowById(WORKFLOW).status), uint256(WorkflowRegistry.WorkflowStatus.PAUSED)
        );
        assertEq(chainlinkRegistry.totalActiveWorkflowsByOwner(address(workflowRegistry)), 0);
        assertEq(workflowRegistry.workflowId(address(oracle)), NEXT_WORKFLOW);
        _assertProposal(address(oracle), bytes32(0));
    }

    function test_PausedWorkflowCanRotateWhileRemainingPaused() public {
        chainlinkRegistry.adminPauseWorkflow(WORKFLOW);
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.status = IChainlinkWorkflowRegistry.WorkflowStatus.PAUSED;
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        assertEq(chainlinkRegistry.getWorkflowById(NEXT_WORKFLOW).tag, params.tag);
        assertEq(
            uint256(chainlinkRegistry.getWorkflowById(NEXT_WORKFLOW).status),
            uint256(WorkflowRegistry.WorkflowStatus.PAUSED)
        );
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(0));
        assertEq(workflowRegistry.workflowId(address(oracle)), NEXT_WORKFLOW);
        _assertProposal(address(oracle), bytes32(0));
    }

    function test_ActiveWorkflowCannotBePausedUsingTheSameTag() public {
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.status = IChainlinkWorkflowRegistry.WorkflowStatus.PAUSED;
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.expectRevert(
            abi.encodeWithSignature(
                "CannotChangeStatusOnUpdate(bytes32,address,string,string,uint8)",
                NEXT_WORKFLOW,
                address(workflowRegistry),
                Strings.toHexString(address(oracle)),
                params.tag,
                uint8(WorkflowRegistry.WorkflowStatus.PAUSED)
            )
        );
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        _assertUnchangedProposal(NEXT_WORKFLOW, params);
    }

    function test_PausedWorkflowCannotBeReactivatedByAcceptance() public {
        chainlinkRegistry.adminPauseWorkflow(WORKFLOW);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(
            abi.encodeWithSignature(
                "CannotChangeStatusOnUpdate(bytes32,address,string,string,uint8)",
                NEXT_WORKFLOW,
                address(workflowRegistry),
                Strings.toHexString(address(oracle)),
                "default",
                uint8(WorkflowRegistry.WorkflowStatus.ACTIVE)
            )
        );
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertProposal(address(oracle), NEXT_WORKFLOW);
        assertEq(workflowRegistry.workflowId(address(oracle)), WORKFLOW);
        assertEq(
            uint256(chainlinkRegistry.getWorkflowById(WORKFLOW).status), uint256(WorkflowRegistry.WorkflowStatus.PAUSED)
        );
        assertEq(chainlinkRegistry.getWorkflowById(NEXT_WORKFLOW).owner, address(0));
    }

    function testFuzz_NewTagReplacesPausedWorkflowOrDON(bool paused, bool changeDON) public {
        if (paused) chainlinkRegistry.adminPauseWorkflow(WORKFLOW);
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.tag = "replacement";
        if (changeDON) {
            params.donFamily = "replacement-don";
            chainlinkRegistry.setDONLimit(params.donFamily, 1, 1);
        } else {
            chainlinkRegistry.setDONLimit(DON_FAMILY, 1, 1);
        }
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);

        WorkflowRegistry.WorkflowMetadataView memory replacement = chainlinkRegistry.getWorkflowById(NEXT_WORKFLOW);
        assertEq(replacement.owner, address(workflowRegistry));
        assertEq(replacement.workflowName, Strings.toHexString(address(oracle)));
        assertEq(replacement.tag, params.tag);
        assertEq(replacement.donFamily, params.donFamily);
        assertEq(uint256(replacement.status), uint256(WorkflowRegistry.WorkflowStatus.ACTIVE));
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(workflowRegistry));
        assertEq(
            uint256(chainlinkRegistry.getWorkflowById(WORKFLOW).status), uint256(WorkflowRegistry.WorkflowStatus.PAUSED)
        );
        assertEq(chainlinkRegistry.totalActiveWorkflowsByOwner(address(workflowRegistry)), 1);
        assertEq(chainlinkRegistry.totalActiveWorkflowsOnDON(params.donFamily), 1);
        assertEq(workflowRegistry.workflowId(address(oracle)), NEXT_WORKFLOW);
        _assertProposal(address(oracle), bytes32(0));

        (bytes memory raw, bytes[] memory signatures) = _signedReport(_report(0), WORKFLOW);
        forwarder.report(address(oracle), raw, "", signatures);
        assertEq(_acceptedSnapshotBlock(), 0);
        (raw, signatures) = _signedReport(_report(0), NEXT_WORKFLOW);
        forwarder.report(address(oracle), raw, "", signatures);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_acceptedSnapshotBlock(), vm.getBlockNumber() - 2);
    }

    function test_NewTagFailurePreservesOldActiveWorkflowAndProposal() public {
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.tag = "replacement";
        params.donFamily = "replacement-don";
        chainlinkRegistry.setDONLimit(params.donFamily, 100, 0);
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.expectRevert(
            abi.encodeWithSignature(
                "MaxWorkflowsPerUserDONExceeded(address,string)", address(workflowRegistry), params.donFamily
            )
        );
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);

        _assertUnchangedProposal(NEXT_WORKFLOW, params);
        assertEq(chainlinkRegistry.getWorkflowById(NEXT_WORKFLOW).owner, address(0));
        assertEq(chainlinkRegistry.totalActiveWorkflowsByOwner(address(workflowRegistry)), 1);
    }

    function test_NewTagPreservesAnotherOraclesActiveWorkflow() public {
        address receiverB = _newOracle(address(this));
        bytes32 otherWorkflow = keccak256("other oracle workflow");
        _proposeWorkflow(receiverB, otherWorkflow);
        _acceptWorkflow(receiverB, otherWorkflow);
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.tag = "replacement";
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);

        _assertRegistration(receiverB, otherWorkflow);
        assertEq(workflowRegistry.workflowId(address(oracle)), NEXT_WORKFLOW);
        assertEq(chainlinkRegistry.totalActiveWorkflowsByOwner(address(workflowRegistry)), 2);
        assertEq(
            uint256(chainlinkRegistry.getWorkflowById(WORKFLOW).status), uint256(WorkflowRegistry.WorkflowStatus.PAUSED)
        );
    }

    function test_EmptyTagFailsWithoutChangingAcceptedWorkflow() public {
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.tag = "";
        workflowRegistry.proposeWorkflow(address(oracle), NEXT_WORKFLOW, params);
        vm.expectRevert(abi.encodeWithSignature("WorkflowTagRequired()"));
        workflowRegistry.acceptWorkflow(address(oracle), NEXT_WORKFLOW, params);
        _assertUnchangedProposal(NEXT_WORKFLOW, params);
    }

    function test_ChainlinkUnlinkingAllowsRelinkingWithAFreshProof() public {
        uint48 expiry = SafeCast.toUint48(block.timestamp + 1 days);
        chainlinkRegistry.unlinkOwner(
            address(workflowRegistry), expiry, _linkSignature(1, expiry, keccak256("test ownership proof"))
        );
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.expectRevert(
            abi.encodeWithSelector(WorkflowRegistry.OwnershipLinkDoesNotExist.selector, address(workflowRegistry))
        );
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        assertEq(workflowRegistry.workflowId(address(oracle)), WORKFLOW);
        _assertProposal(address(oracle), NEXT_WORKFLOW);
        uint48 newExpiry = SafeCast.toUint48(block.timestamp + 1 days);
        bytes32 newProof = keccak256("replacement test ownership proof");
        bytes memory signature = _linkSignature(0, newExpiry, newProof);
        workflowRegistry.linkOwner(newExpiry, newProof, signature);
        assertTrue(chainlinkRegistry.isOwnerLinked(address(workflowRegistry)));
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(0));
        // The unlink already deleted the old registration; acceptance tolerates the missing record.
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        assertEq(workflowRegistry.workflowId(address(oracle)), NEXT_WORKFLOW);
        assertEq(chainlinkRegistry.getWorkflowById(NEXT_WORKFLOW).owner, address(workflowRegistry));
    }

    function test_ReusedStaleIdCannotDeliverAnotherOraclesReportAfterRelinking() public {
        uint48 expiry = SafeCast.toUint48(block.timestamp + 1 days);
        chainlinkRegistry.unlinkOwner(
            address(workflowRegistry), expiry, _linkSignature(1, expiry, keccak256("test ownership proof"))
        );
        _linkWorkflowRegistry(keccak256("replacement test ownership proof"));

        address otherCurator = makeAddr("independent curator");
        address receiverB = _newOracle(otherCurator);
        _proposeWorkflow(receiverB, WORKFLOW);
        vm.prank(otherCurator);
        _acceptWorkflow(receiverB, WORKFLOW);
        assertEq(workflowRegistry.workflowId(address(oracle)), WORKFLOW);
        assertEq(workflowRegistry.workflowId(receiverB), WORKFLOW);
        _assertRegistration(receiverB, WORKFLOW);

        bytes memory metadata =
            abi.encodePacked(WORKFLOW, encodeWorkflowName(receiverB), address(workflowRegistry), bytes2(0));
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracle.InvalidWorkflow.selector);
        oracle.onReport(metadata, abi.encode(_report(0)));
        assertEq(_acceptedSnapshotBlock(), 0);
        assertEq(oracle.rejectedReportHash(), bytes32(0));

        ICREOracle.Report memory update = _report(0);
        update.adapter = CREOracle(receiverB).adapter();
        vm.prank(address(forwarder));
        CREOracle(receiverB).onReport(metadata, abi.encode(update));
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_acceptedSnapshotBlock(receiverB), update.snapshotBlock);
        assertEq(_acceptedSnapshotBlock(), 0);
    }

    function test_AcceptanceDoesNotReadOracleRegistry() public {
        address originalRegistry = address(workflowRegistry);
        workflowRegistry = new CREWorkflowRegistry(address(this), address(chainlinkRegistry));
        _linkWorkflowRegistry(keccak256("other registry proof"));
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertProposal(address(oracle), NEXT_WORKFLOW);
        assertEq(oracle.WORKFLOW_REGISTRY(), originalRegistry);
        vm.mockCallRevert(
            address(oracle),
            abi.encodeCall(ICREOracle.WORKFLOW_REGISTRY, ()),
            abi.encodeWithSignature("UnexpectedRegistryRead()")
        );
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertProposal(address(oracle), bytes32(0));
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
        assertEq(CREWorkflowRegistry(originalRegistry).workflowId(address(oracle)), WORKFLOW);
        assertEq(chainlinkRegistry.totalActiveWorkflowsByOwner(address(workflowRegistry)), 1);
        workflowRegistry = CREWorkflowRegistry(originalRegistry);
        _assertRegistration(address(oracle), WORKFLOW);
    }

    function test_WorkflowChangePreservesAccountingAndRejectedReportReview() public {
        _deliverWithReview(_report(100));
        _advanceReport();
        ICREOracle.Report memory rejected = _report(300);
        _deliver(rejected);
        bytes memory payload = abi.encode(rejected);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        assertEq(workflowRegistry.workflowId(address(oracle)), NEXT_WORKFLOW);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        assertEq(adapter.totalAssets(), 100);
        assertEq(_acceptedSnapshotBlock(), 499);

        oracle.acceptReport(payload);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 300);
        assertEq(_acceptedSnapshotBlock(), rejected.snapshotBlock);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_WorkflowChangePreservesDelayedNAV() public {
        _deliver(_report(0));
        vm.warp(block.timestamp + 365 days);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        assertEq(adapter.totalAssets(), 0);
    }

    function test_NewWorkflowContinuesSnapshotSequenceAndOldWorkflowIsRejectedByRealForwarder() public {
        _deliverWithReview(_report(100));
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _advanceReport();
        ICREOracle.Report memory update = _report(105);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, NEXT_WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertFalse(
            forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(update.snapshotBlock)), bytes2(0)).success
        );
        assertEq(_acceptedSnapshotBlock(), 499);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        (raw, signatures) = _signedReport(update, WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertFalse(
            forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(update.snapshotBlock)), bytes2(0)).success
        );
        assertEq(_acceptedSnapshotBlock(), 499);
        (raw, signatures) = _signedReport(update, NEXT_WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertTrue(
            forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(update.snapshotBlock)), bytes2(0)).success
        );
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_acceptedSnapshotBlock(), update.snapshotBlock);
        assertEq(adapter.totalAssets(), 105);
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
            adapter: adapterB,
            totalAssets: 0,
            snapshotBlock: SafeCast.toUint48(block.number - 1)
        });
        _workflowName = encodeWorkflowName(receiverB);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, WORKFLOW);
        forwarder.report(receiverB, raw, "", signatures);
        assertEq(_acceptedSnapshotBlock(receiverB), 0);
        (raw, signatures) = _signedReport(update, NEXT_WORKFLOW);
        forwarder.report(receiverB, raw, "", signatures);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_acceptedSnapshotBlock(receiverB), update.snapshotBlock);
    }

    function test_AcceptanceStoresWorkflowWithoutWritingOracle() public {
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        vm.record();
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        (, bytes32[] memory writes) = vm.accesses(address(oracle));
        assertEq(writes.length, 0);
        _assertProposal(address(oracle), bytes32(0));
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
    }

    function test_RotationPreservesAnotherOraclesMappingAndRegistration() public {
        address adapterB = AdapterFactory(adapter.FACTORY())
            .create(1, address(this), abi.encode(adapter.vault(), abi.encode(merkleAdapterInitParams(address(this)))));
        address receiverB = MerkleAdapter(payable(adapterB)).oracle();
        _proposeWorkflow(receiverB, NEXT_WORKFLOW);
        _acceptWorkflow(receiverB, NEXT_WORKFLOW);
        bytes32 replacement = keccak256("A v2");
        _proposeWorkflow(address(oracle), replacement);
        _acceptWorkflow(address(oracle), replacement);
        _assertRegistration(address(oracle), replacement);
        _assertRegistration(receiverB, NEXT_WORKFLOW);
    }

    function test_AlreadyRegisteredIdCannotBeAccepted() public {
        _proposeWorkflow(address(oracle), WORKFLOW);
        vm.expectRevert(abi.encodeWithSelector(WorkflowRegistry.WorkflowIDAlreadyExists.selector, WORKFLOW));
        _acceptWorkflow(address(oracle), WORKFLOW);
        _assertUnchangedProposal(WORKFLOW, _workflowParams());
    }

    function test_ReplacementToleratesUpstreamDeletedRegistration() public {
        vm.prank(address(workflowRegistry));
        IChainlinkWorkflowRegistry(address(chainlinkRegistry)).deleteWorkflow(WORKFLOW);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
    }

    function test_DeletedIdClaimedByAnotherOwnerCannotBlockRotation() public {
        CREWorkflowRegistry originalRegistry = workflowRegistry;
        vm.prank(address(originalRegistry));
        IChainlinkWorkflowRegistry(address(chainlinkRegistry)).deleteWorkflow(WORKFLOW);

        workflowRegistry = new CREWorkflowRegistry(address(this), address(chainlinkRegistry));
        _linkWorkflowRegistry(keccak256("another organization"));
        address otherOwner = address(workflowRegistry);
        vm.prank(otherOwner);
        IChainlinkWorkflowRegistry(address(chainlinkRegistry))
            .upsertWorkflow(
                "other workflow",
                "default",
                WORKFLOW,
                IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE,
                DON_FAMILY,
                "https://example.com/other.wasm",
                "",
                "",
                false
            );
        workflowRegistry = originalRegistry;

        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, otherOwner);
    }

    function test_RotationAtCapacityKeepsExistingSlot() public {
        chainlinkRegistry.setDONLimit(DON_FAMILY, 1, 1);
        _proposeWorkflow(address(oracle), NEXT_WORKFLOW);
        _acceptWorkflow(address(oracle), NEXT_WORKFLOW);
        _assertRegistration(address(oracle), NEXT_WORKFLOW);
        assertEq(chainlinkRegistry.totalActiveWorkflowsOnDON(DON_FAMILY), 1);
    }

    function _newOracle(address curator) internal returns (address) {
        address newAdapter = AdapterFactory(adapter.FACTORY())
            .create(1, curator, abi.encode(adapter.vault(), abi.encode(merkleAdapterInitParams(curator))));
        return MerkleAdapter(payable(newAdapter)).oracle();
    }

    function _assertUnchangedProposal() internal view {
        _assertUnchangedProposal(NEXT_WORKFLOW, _workflowParams());
    }

    function _assertUnchangedProposal(bytes32 id, ICREWorkflowRegistry.WorkflowParams memory params) internal view {
        assertEq(workflowRegistry.workflowId(address(oracle)), WORKFLOW);
        _assertProposal(address(oracle), id, params);
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
        assertEq(workflowRegistry.workflowId(receiver), id);
    }
}
