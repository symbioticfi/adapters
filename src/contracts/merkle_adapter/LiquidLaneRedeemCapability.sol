// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Capability} from "./Capability.sol";

import {ILiquidLaneReactor} from "../../interfaces/merkle_adapter/ILiquidLaneReactor.sol";
import {
    ILiquidLaneRedeemCapability,
    ILiquidLaneRedeemCapabilityConstants
} from "../../interfaces/merkle_adapter/ILiquidLaneRedeemCapability.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title LiquidLaneRedeemCapability
/// @notice Contract for storing Liquid Lane consumer signatures through the adapter's delegatecall routing.
contract LiquidLaneRedeemCapability layout at erc7201("symbiotic.storage.LiquidLaneRedeemCapability")
    is
    Capability,
    ILiquidLaneRedeemCapabilityConstants,
    ILiquidLaneRedeemCapability
{
    /* IMMUTABLES */

    /// @inheritdoc ILiquidLaneRedeemCapability
    address public immutable REACTOR;

    /// @inheritdoc ILiquidLaneRedeemCapability
    address public immutable PROTOCOL;

    /* STATE VARIABLES */

    mapping(address tokenIn => bytes32 digest) internal _activeRequest;
    mapping(bytes32 digest => bytes signature) internal _signatures;
    mapping(bytes32 digest => Authorization authorization) internal _authorizations;
    mapping(uint256 nonce => bool active) internal _activeNonces;

    /* CONSTRUCTOR */

    /// @dev Pins the Reactor and protocol signer in the exact implementation approved by the registry.
    constructor(address newReactor, address newProtocol) {
        REACTOR = newReactor;
        PROTOCOL = newProtocol;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ILiquidLaneRedeemCapability
    function activeRequest(address tokenIn) public view returns (bytes32) {
        return _activeRequest[tokenIn];
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function signatures(bytes32 digest) public view returns (bytes memory) {
        return _signatures[digest];
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function signRequest(ILiquidLaneReactor.Request calldata request, bytes calldata signature)
        public
        onlyMyself
        returns (bytes32 digest)
    {
        if (request.tokenIn == address(0) || request.amountIn == 0 || request.deadline < block.timestamp) {
            revert InvalidRequest();
        }

        if (signature.length == 0) revert InvalidSignature();

        if (request.protocol != PROTOCOL) revert InvalidProtocol();

        if (request.outputs.length == 0) revert InvalidOutput();

        for (uint256 i; i < request.outputs.length; ++i) {
            if (request.outputs[i].recipient != address(this) || request.outputs[i].amount == 0) {
                revert InvalidOutput();
            }
        }
        if (_activeRequest[request.tokenIn] != bytes32(0) || _activeNonces[request.nonce]) revert ActiveRequest();

        if (ILiquidLaneReactor(REACTOR).isUsedNonce(address(this), request.nonce)) revert NonceUsed();

        digest = hashRequest(request);
        _signatures[digest] = signature;
        _authorizations[digest] = Authorization({
            tokenIn: request.tokenIn,
            reactor: REACTOR,
            protocol: PROTOCOL,
            chainId: block.chainid,
            nonce: request.nonce,
            deadline: request.deadline
        });
        _activeRequest[request.tokenIn] = digest;
        _activeNonces[request.nonce] = true;

        emit SignRequest(digest, request.tokenIn, request.nonce, request.amountIn, request.deadline, signature);
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function revokeRequest(bytes32 digest) public onlyMyself {
        Authorization storage authorization = _authorizations[digest];
        if (authorization.tokenIn == address(0)) revert UnknownRequest();

        delete _signatures[digest];
        ILiquidLaneReactor(authorization.reactor).invalidateNonce(authorization.nonce);

        emit RevokeRequest(digest);
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function finalizeRequest(bytes32 digest) public onlyMyself {
        Authorization storage authorization = _authorizations[digest];
        if (authorization.tokenIn == address(0)) revert UnknownRequest();

        if (
            _signatures[digest].length != 0 && block.timestamp <= authorization.deadline
                && !ILiquidLaneReactor(authorization.reactor).isUsedNonce(address(this), authorization.nonce)
        ) revert RequestNotFinished();

        delete _signatures[digest];
        delete _activeRequest[authorization.tokenIn];
        delete _activeNonces[authorization.nonce];
        delete _authorizations[digest];

        emit FinalizeRequest(digest);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 digest, bytes calldata signature) public view returns (bytes4) {
        Authorization storage authorization = _authorizations[digest];
        if (
            authorization.tokenIn == address(0) || signature.length == 0 || authorization.chainId != block.chainid
                || authorization.reactor != REACTOR || authorization.protocol != PROTOCOL
                || block.timestamp > authorization.deadline || keccak256(signature) != keccak256(_signatures[digest])
                || ILiquidLaneReactor(REACTOR).isUsedNonce(address(this), authorization.nonce)
        ) {
            return 0xffffffff;
        }
        return IERC1271.isValidSignature.selector;
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function hashRequest(ILiquidLaneReactor.Request calldata request) public view returns (bytes32 digest) {
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
