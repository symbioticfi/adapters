// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";
import {IWorkflowRegistry as WorkflowRegistry} from "test/mocks/chainlink-cre/interfaces/IWorkflowRegistry.sol";

/// @dev Exercises the deployed v2 registry at a fixed block. Governance is impersonated only to authorize
/// the fixture's link-proof signer and test DON; no live transaction, CRE upload or execution is performed.
contract CREWorkflowRegistryMainnetTest is CREOracleTestBase {
    address internal provider;
    address internal curator;

    function setUp() public override {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "ETH_RPC_URL is required for Chainlink workflow registry integration");
            return;
        }
        // Keep synthetic owner accounts local so rotation needs no historical RPC state for unused addresses.
        provider = makeAddr("rotated Symbiotic owner");
        curator = makeAddr("rotated curator owner");
        vm.deal(provider, 1 ether);
        vm.deal(curator, 1 ether);
        vm.makePersistent(provider, curator);
        vm.createSelectFork(rpc, 26_032_120);
        super.setUp();
    }

    // Retain the pinned fork's block/time rather than requesting unit-test-era historical block hashes.
    function _setUpReportContext() internal override {}

    function _deployChainlinkRegistry() internal override {
        chainlinkRegistry = WorkflowRegistry(0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5);
        assertEq(chainlinkRegistry.typeAndVersion(), "WorkflowRegistry 2.0.0");
        address[] memory signers = new address[](1);
        signers[0] = vm.addr(LINK_SIGNER_KEY);
        address registryOwner = chainlinkRegistry.owner();
        vm.startPrank(registryOwner);
        chainlinkRegistry.updateAllowedSigners(signers, true);
        chainlinkRegistry.setDONLimit(DON_FAMILY, 100, 100);
        vm.stopPrank();
    }

    function test_MainnetRegistrationReplacementAndReport() public {
        vm.expectRevert(abi.encodeWithSignature("OwnershipLinkAlreadyExists(address)", address(workflowRegistry)));
        workflowRegistry.linkOwner(SafeCast.toUint48(block.timestamp + 1 hours), bytes32(0), "");
        WorkflowRegistry.WorkflowMetadataView memory registered = chainlinkRegistry.getWorkflowById(WORKFLOW);
        assertEq(registered.owner, address(workflowRegistry));
        assertEq(registered.workflowId, WORKFLOW);
        assertEq(registered.workflowName, Strings.toHexString(address(oracle)));
        assertEq(registered.tag, "default");
        assertEq(registered.binaryUrl, _workflowParams().binaryUrl);
        assertEq(registered.configUrl, _workflowParams().configUrl);
        assertEq(registered.attributes, _workflowParams().attributes);
        assertEq(uint256(registered.status), uint256(WorkflowRegistry.WorkflowStatus.ACTIVE));
        _deliverWithReview(_report(100));
        workflowRegistry.transferOwnership(provider);
        oracle.transferOwnership(curator);
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(workflowRegistry));
        bytes32 nextWorkflow = keccak256("mainnet registry replacement");
        vm.prank(provider);
        _proposeWorkflow(address(oracle), nextWorkflow);
        vm.prank(curator);
        _acceptWorkflow(address(oracle), nextWorkflow);
        registered = chainlinkRegistry.getWorkflowById(nextWorkflow);
        assertEq(registered.owner, address(workflowRegistry));
        assertEq(registered.workflowId, nextWorkflow);
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(0));
        assertEq(workflowRegistry.workflowId(address(oracle)), nextWorkflow);
        assertEq(oracle.snapshotBlock(), block.number - 1);
        _advanceReport();
        (bytes memory raw, bytes[] memory signatures) = _signedReport(_report(105), nextWorkflow);
        forwarder.report(address(oracle), raw, "", signatures);
        assertEq(oracle.snapshotBlock(), block.number - 1);
        assertEq(adapter.totalAssets(), 105);
    }

    function test_MainnetFailedRegistrationPreservesOldWorkflow() public {
        bytes32 nextWorkflow = keccak256("invalid mainnet replacement");
        ICREWorkflowRegistry.WorkflowParams memory params = _workflowParams();
        params.binaryUrl = "";
        workflowRegistry.proposeWorkflow(address(oracle), nextWorkflow, params);
        vm.expectRevert(WorkflowRegistry.BinaryURLRequired.selector);
        workflowRegistry.acceptWorkflow(address(oracle), nextWorkflow, params);
        assertEq(chainlinkRegistry.getWorkflowById(WORKFLOW).owner, address(workflowRegistry));
        assertEq(workflowRegistry.workflowId(address(oracle)), WORKFLOW);
        _assertProposal(address(oracle), nextWorkflow, params);
    }
}
