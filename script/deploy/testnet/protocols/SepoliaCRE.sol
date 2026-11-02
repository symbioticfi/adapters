// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OfficialCRE} from "../../merkle/OfficialCRE.sol";
import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Test-stand registration authority on mainnet; owns no production portfolio.
contract SepoliaCRERegistrationOwner is Ownable {
    constructor(address newOwner) Ownable(newOwner) {}

    /// @notice Forwards the CRE CLI's unsigned linking, registration or unlinking transaction.
    function execute(bytes calldata data) public onlyOwner returns (bytes memory result) {
        bool success;
        (success, result) = OfficialCRE.MAINNET_REGISTRY.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

/// @notice Identical CREATE2 init code gives its first CREATE child the same address on both chains.
contract SepoliaCREPair {
    address public immutable workflowOwner;

    constructor(address newOwner, address newReplica) {
        if (block.chainid == 1) {
            workflowOwner = address(new SepoliaCRERegistrationOwner(newOwner));
        } else {
            require(block.chainid == 11_155_111, "Sepolia CRE pair: wrong chain");
            workflowOwner = address(new CREWorkflowRegistry(newOwner, newReplica));
        }
    }
}

/// @notice Deterministic test-only owner pair. The production Merkle contracts are unchanged.
library SepoliaCRE {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    error InvalidPair();

    function deploy(address owner, address replica) internal returns (address workflowOwner) {
        bytes memory initCode = abi.encodePacked(type(SepoliaCREPair).creationCode, abi.encode(owner, replica));
        bytes32 salt = keccak256(abi.encode("Sepolia CRE test stand", owner, replica));
        address pair = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(initCode)))))
        );
        // CREATE nonce one depends on the parent address, not on the child's chain-specific init code.
        workflowOwner = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", pair, hex"01")))));
        if (pair.code.length == 0) {
            if (CREATE2_DEPLOYER.code.length == 0) revert InvalidPair();
            (bool success,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
            if (!success || pair.code.length == 0) revert InvalidPair();
        }
        if (
            SepoliaCREPair(pair).workflowOwner() != workflowOwner || workflowOwner.code.length == 0
                || Ownable(workflowOwner).owner() != owner
        ) revert InvalidPair();
        if (block.chainid == 11_155_111 && CREWorkflowRegistry(workflowOwner).CHAINLINK_WORKFLOW_REGISTRY() != replica) revert InvalidPair();
    }
}
