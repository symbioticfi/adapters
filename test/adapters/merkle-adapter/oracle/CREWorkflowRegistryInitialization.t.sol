// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";
import {IWorkflowRegistry as WorkflowRegistry} from "test/mocks/chainlink-cre/interfaces/IWorkflowRegistry.sol";

contract CREWorkflowRegistryInitializationTest is CREOracleTestBase {
    function _setUpWorkflowRegistry() internal override {
        _deployChainlinkRegistry();
        workflowRegistry = new CREWorkflowRegistry(address(this), address(chainlinkRegistry));
    }

    function _setUpAcceptedWorkflow() internal override {}

    function test_OneTimeLinkNeedsNoAcceptance() public {
        _linkWorkflowRegistry(keccak256("test ownership proof"));
        assertTrue(workflowRegistry.initialized());
        assertTrue(chainlinkRegistry.isOwnerLinked(address(workflowRegistry)));
        assertEq(oracle.workflowId(), bytes32(0));
        vm.expectRevert(ICREWorkflowRegistry.AlreadyInitialized.selector);
        workflowRegistry.linkOwner(block.timestamp + 1 days, bytes32(0), "");

        _proposeWorkflow(address(oracle), WORKFLOW);
        _acceptWorkflow(address(oracle), WORKFLOW);
        vm.expectRevert(ICREWorkflowRegistry.AlreadyInitialized.selector);
        workflowRegistry.linkOwner(block.timestamp + 1 days, bytes32(0), "");
        assertEq(oracle.workflowId(), WORKFLOW);
    }

    function testFuzz_OnlyCurrentOwnerCanLink(address provider) public {
        vm.assume(provider != address(0) && provider != address(this));
        workflowRegistry.transferOwnership(provider);
        uint256 expiry = block.timestamp + 1 days;
        bytes32 proof = keccak256("test ownership proof");
        bytes memory signature = _linkSignature(0, expiry, proof);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        workflowRegistry.linkOwner(expiry, proof, signature);
        assertFalse(workflowRegistry.initialized());
        vm.prank(provider);
        workflowRegistry.linkOwner(expiry, proof, signature);
        assertTrue(workflowRegistry.initialized());
        assertTrue(chainlinkRegistry.isOwnerLinked(address(workflowRegistry)));
    }

    function test_FailedLinkCanBeRetried() public {
        uint256 expiry = block.timestamp - 1;
        bytes32 proof = keccak256("test ownership proof");
        bytes memory signature = _linkSignature(0, expiry, proof);
        vm.expectRevert(
            abi.encodeWithSelector(
                WorkflowRegistry.LinkOwnerRequestExpired.selector, address(workflowRegistry), block.timestamp, expiry
            )
        );
        workflowRegistry.linkOwner(expiry, proof, signature);
        assertFalse(workflowRegistry.initialized());
        assertFalse(chainlinkRegistry.isOwnerLinked(address(workflowRegistry)));
        _linkWorkflowRegistry(proof);
        assertTrue(workflowRegistry.initialized());
        assertTrue(chainlinkRegistry.isOwnerLinked(address(workflowRegistry)));
    }

    function test_UnlinkedRegistryCannotAcceptAndProposalSurvives() public {
        _proposeWorkflow(address(oracle), WORKFLOW);
        vm.expectRevert(
            abi.encodeWithSelector(WorkflowRegistry.OwnershipLinkDoesNotExist.selector, address(workflowRegistry))
        );
        _acceptWorkflow(address(oracle), WORKFLOW);
        assertFalse(workflowRegistry.initialized());
        _assertUnregistered(_proposalHash(WORKFLOW));
        _linkWorkflowRegistry(keccak256("test ownership proof"));
        _acceptWorkflow(address(oracle), WORKFLOW);
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(workflowRegistry.proposals(address(oracle)), bytes32(0));
    }

    function test_NoOffchainRequestAuthorization() public {
        _linkWorkflowRegistry(keccak256("test ownership proof"));
        bytes32 digest = keccak256("request");
        (bool success,) = address(workflowRegistry)
            .call(
                abi.encodeWithSignature("allowlistRequest(bytes32,uint32)", digest, uint32(block.timestamp + 1 hours))
            );
        assertFalse(success);
        assertFalse(chainlinkRegistry.isRequestAllowlisted(address(workflowRegistry), digest));
    }

    function test_FirstRegistrationFailurePreservesLinkAndProposal() public {
        _linkWorkflowRegistry(keccak256("test ownership proof"));
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.binaryUrl = "";
        workflowRegistry.proposeWorkflow(address(oracle), WORKFLOW, params);
        vm.expectRevert(WorkflowRegistry.BinaryURLRequired.selector);
        workflowRegistry.acceptWorkflow(address(oracle), WORKFLOW, params);
        _assertUnregistered(keccak256(abi.encode(WORKFLOW, params)));
        assertTrue(workflowRegistry.initialized());
        assertTrue(chainlinkRegistry.isOwnerLinked(address(workflowRegistry)));
        _proposeWorkflow(address(oracle), WORKFLOW);
        _acceptWorkflow(address(oracle), WORKFLOW);
        assertEq(oracle.workflowId(), WORKFLOW);
    }

    function test_FirstReceiverFailurePreservesLinkAndProposal() public {
        _linkWorkflowRegistry(keccak256("test ownership proof"));
        _proposeWorkflow(address(oracle), WORKFLOW);
        bytes memory failure = abi.encodeWithSignature("ReceiverFailure()");
        vm.mockCallRevert(address(oracle), abi.encodeCall(ICREOracle.setWorkflowId, (WORKFLOW)), failure);
        vm.expectRevert(failure);
        _acceptWorkflow(address(oracle), WORKFLOW);
        vm.clearMockedCalls();
        _assertUnregistered(_proposalHash(WORKFLOW));
        assertTrue(workflowRegistry.initialized());
        _acceptWorkflow(address(oracle), WORKFLOW);
        assertEq(oracle.workflowId(), WORKFLOW);
    }

    function test_RenunciationDoesNotChangeInitialCuratorAcceptance() public {
        _linkWorkflowRegistry(keccak256("test ownership proof"));
        _proposeWorkflow(address(oracle), WORKFLOW);
        workflowRegistry.renounceOwnership();
        assertEq(workflowRegistry.owner(), address(0));
        _acceptWorkflow(address(oracle), WORKFLOW);
        assertTrue(workflowRegistry.initialized());
        assertEq(oracle.workflowId(), WORKFLOW);
    }

    function _assertUnregistered(bytes32 proposalHash) internal view {
        assertEq(workflowRegistry.workflowIds(address(oracle)), bytes32(0));
        assertEq(oracle.workflowId(), bytes32(0));
        assertEq(workflowRegistry.proposals(address(oracle)), proposalHash);
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(0));
    }
}
