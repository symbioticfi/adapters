// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IMerkleAccount} from "../../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";
import {
    LIQUID_LANE_OUTPUT_TYPEHASH,
    LIQUID_LANE_REQUEST_TYPEHASH
} from "../../interfaces/merkle-adapter/ILiquidLaneReactor.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";

/// @title MerkleAccount
/// @notice Contract for strategy custody and execution authorized by its MerkleAdapter.
contract MerkleAccount is Proxy, IMerkleAccount {
    using Address for address;

    /* IMMUTABLES */

    /// @inheritdoc IMerkleAccount
    address public immutable adapter;

    /* STATE VARIABLES */

    /// @inheritdoc IMerkleAccount
    mapping(bytes32 digest => bool approved) public signatures;

    /* CONSTRUCTOR */

    constructor() {
        adapter = msg.sender;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMerkleAccount
    function execute(IMerkleAdapter.Action[] calldata actions) public returns (bytes[] memory results) {
        if (adapter != msg.sender) revert InvalidCaller();

        results = new bytes[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            IMerkleAdapter.Action calldata action = actions[i];
            results[i] = action.target.functionCallWithValue(action.data, action.value);
        }
    }

    /// @inheritdoc IMerkleAccount
    function setSignature(bytes32 domain, bytes calldata signature) public {
        if (address(this) != msg.sender) revert InvalidCaller();

        bytes32 structHash = keccak256(signature);
        if (bytes32(signature[:32]) == LIQUID_LANE_REQUEST_TYPEHASH) {
            if (signature.length != 288) revert InvalidSignature();
            // The single output stays explicit in the leaf; EIP-712 hashes its struct and then its array.
            structHash = keccak256(
                abi.encodePacked(
                    signature[:96],
                    keccak256(abi.encode(keccak256(abi.encodePacked(LIQUID_LANE_OUTPUT_TYPEHASH, signature[96:192])))),
                    signature[192:]
                )
            );
        }
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, structHash);
        signatures[digest] = true;
        emit SetSignature(digest, signature);
    }

    /// @inheritdoc IMerkleAccount
    function revokeSignature(bytes32 digest) public {
        if (address(this) != msg.sender) revert InvalidCaller();

        delete signatures[digest];
        emit RevokeSignature(digest);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 digest, bytes calldata) public view returns (bytes4) {
        return signatures[digest] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Capabilities execute in account storage; configuration stays on the adapter.
    function _implementation() internal view override returns (address capability) {
        capability = IMerkleAdapter(adapter).capabilityBySelector(msg.sig);
        if (msg.data.length < 4 || capability == address(0)) revert UnknownSelector();
    }

    /* RECEIVE FUNCTION */

    receive() external payable {}
}
