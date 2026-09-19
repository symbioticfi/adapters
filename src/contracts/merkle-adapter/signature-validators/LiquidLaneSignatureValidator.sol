// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ILiquidLaneReactor} from "../../../interfaces/merkle-adapter/signature-validators/ILiquidLaneReactor.sol";
import {
    ILiquidLaneSignatureValidator,
    ILiquidLaneSignatureValidatorConstants
} from "../../../interfaces/merkle-adapter/signature-validators/ILiquidLaneSignatureValidator.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title LiquidLaneSignatureValidator
/// @notice Contract for validating Liquid Lane requests authorized by a calling Merkle adapter.
contract LiquidLaneSignatureValidator is ILiquidLaneSignatureValidatorConstants, ILiquidLaneSignatureValidator {
    /* IMMUTABLES */

    /// @inheritdoc ILiquidLaneSignatureValidator
    address public immutable REACTOR;

    /// @inheritdoc ILiquidLaneSignatureValidator
    address public immutable PROTOCOL;

    /* CONSTRUCTOR */

    constructor(address newReactor, address newProtocol) {
        REACTOR = newReactor;
        PROTOCOL = newProtocol;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ILiquidLaneSignatureValidator
    function isValidSignature(bytes32 digest, bytes calldata signature) public view returns (bytes4) {
        ILiquidLaneReactor.Request memory request = abi.decode(signature, (ILiquidLaneReactor.Request));
        if (
            request.tokenIn == address(0) || request.amountIn == 0 || request.outputs.length == 0
                || request.protocol != PROTOCOL || request.deadline < block.timestamp || hashRequest(request) != digest
                || ILiquidLaneReactor(REACTOR).isUsedNonce(msg.sender, request.nonce)
        ) return 0xffffffff;

        for (uint256 i; i < request.outputs.length; ++i) {
            if (request.outputs[i].recipient != msg.sender || request.outputs[i].amount == 0) return 0xffffffff;
        }
        return IERC1271.isValidSignature.selector;
    }

    /// @inheritdoc ILiquidLaneSignatureValidator
    function hashRequest(ILiquidLaneReactor.Request memory request) public view returns (bytes32 digest) {
        bytes32[] memory outputHashes = new bytes32[](request.outputs.length);
        for (uint256 i; i < request.outputs.length; ++i) {
            outputHashes[i] = keccak256(abi.encode(OUTPUT_TYPEHASH, request.outputs[i]));
        }
        digest = MessageHashUtils.toTypedDataHash(
            keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, REACTOR)),
            keccak256(
                abi.encode(
                    REQUEST_TYPEHASH,
                    request.tokenIn,
                    request.amountIn,
                    keccak256(abi.encodePacked(outputHashes)),
                    request.deadline,
                    request.nonce,
                    request.protocol
                )
            )
        );
    }
}
