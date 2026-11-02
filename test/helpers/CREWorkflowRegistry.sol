// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IChainlinkWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/IChainlinkWorkflowRegistry.sol";
import {IWorkflowRegistry as WorkflowRegistry} from "test/mocks/chainlink-cre/interfaces/IWorkflowRegistry.sol";
import {Test} from "forge-std/Test.sol";

abstract contract CREWorkflowRegistryTestHelper is Test {
    // Test-only trusted signer, configured only on the local Chainlink registry fixture.
    uint256 internal constant LINK_SIGNER_KEY = 0xC0DE;
    string internal constant DON_FAMILY = "test-don";
    WorkflowRegistry internal chainlinkRegistry;
    CREWorkflowRegistry internal workflowRegistry;

    function _deployChainlinkRegistry() internal virtual {
        chainlinkRegistry = WorkflowRegistry(deployCode("WorkflowRegistry.sol:WorkflowRegistry"));
        address[] memory signers = new address[](1);
        signers[0] = vm.addr(LINK_SIGNER_KEY);
        chainlinkRegistry.updateAllowedSigners(signers, true);
        chainlinkRegistry.setDONLimit(DON_FAMILY, 100, 100);
    }

    function _setUpWorkflowRegistry() internal virtual {
        _deployChainlinkRegistry();
        workflowRegistry = new CREWorkflowRegistry(address(this), address(chainlinkRegistry));
        _linkWorkflowRegistry(keccak256("test ownership proof"));
    }

    function _linkWorkflowRegistry(bytes32 proof) internal {
        uint48 expiry = SafeCast.toUint48(block.timestamp + 1 days);
        workflowRegistry.linkOwner(expiry, proof, _linkSignature(0, expiry, proof));
    }

    function _linkSignature(uint8 requestType, uint256 expiry, bytes32 proof) internal view returns (bytes memory) {
        bytes32 hash = keccak256(
            abi.encode(
                requestType,
                address(workflowRegistry),
                block.chainid,
                address(chainlinkRegistry),
                "WorkflowRegistry 2.0.0",
                expiry,
                proof
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(LINK_SIGNER_KEY, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        return abi.encodePacked(r, s, v);
    }

    function _workflowParams() internal pure returns (ICREWorkflowRegistry.WorkflowParams memory) {
        return ICREWorkflowRegistry.WorkflowParams({
            tag: "default",
            status: IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE,
            donFamily: DON_FAMILY,
            binaryUrl: "https://example.com/nav.wasm.br",
            configUrl: "https://example.com/nav.json",
            attributes: hex"0102"
        });
    }

    function _proposeWorkflow(address receiver, bytes32 id) internal {
        workflowRegistry.proposeWorkflow(receiver, id, _workflowParams());
    }

    function _acceptWorkflow(address receiver, bytes32 id) internal {
        workflowRegistry.acceptWorkflow(receiver, id, _workflowParams());
    }

    function _assertProposal(address receiver, bytes32 id) internal view {
        _assertProposal(
            receiver,
            id,
            id == bytes32(0)
                ? ICREWorkflowRegistry.WorkflowParams({
                    tag: "",
                    status: IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE,
                    donFamily: "",
                    binaryUrl: "",
                    configUrl: "",
                    attributes: ""
                })
                : _workflowParams()
        );
    }

    function _assertProposal(address receiver, bytes32 id, ICREWorkflowRegistry.WorkflowParams memory params)
        internal
        view
    {
        assertEq(workflowRegistry.proposedWorkflowId(receiver), id);
        (
            string memory tag,
            IChainlinkWorkflowRegistry.WorkflowStatus status,
            string memory donFamily,
            string memory binaryUrl,
            string memory configUrl,
            bytes memory attributes
        ) = workflowRegistry.proposedWorkflowParams(receiver);
        assertEq(tag, params.tag);
        assertEq(uint256(status), uint256(params.status));
        assertEq(donFamily, params.donFamily);
        assertEq(binaryUrl, params.binaryUrl);
        assertEq(configUrl, params.configUrl);
        assertEq(attributes, params.attributes);
    }
}
