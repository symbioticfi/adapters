// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
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
        uint256 expiry = block.timestamp + 1 days;
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

    function _proposalHash(bytes32 id) internal pure returns (bytes32) {
        return id == bytes32(0) ? bytes32(0) : keccak256(abi.encode(id, _workflowParams()));
    }
}
