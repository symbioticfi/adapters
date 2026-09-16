// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

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
contract LiquidLaneRedeemCapability is Capability, ILiquidLaneRedeemCapabilityConstants, ILiquidLaneRedeemCapability {
    /* IMMUTABLES */

    /// @inheritdoc ILiquidLaneRedeemCapability
    address public immutable REACTOR;

    /// @inheritdoc ILiquidLaneRedeemCapability
    address public immutable PROTOCOL;

    /* STATE VARIABLES */

    /// @dev Isolated adapter storage retained when this capability is removed or replaced.
    struct RedeemStorage {
        mapping(address tokenIn => bytes32 digest) activeRequest;
        mapping(bytes32 digest => bytes signature) signatures;
        mapping(bytes32 digest => Authorization authorization) authorizations;
        mapping(uint256 nonce => bool active) activeNonces;
    }

    /* CONSTRUCTOR */

    /// @dev Pins the Reactor and protocol signer in the exact implementation approved by the registry.
    constructor(address newReactor, address newProtocol) {
        REACTOR = newReactor;
        PROTOCOL = newProtocol;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ILiquidLaneRedeemCapability
    function activeRequest(address tokenIn) public view returns (bytes32) {
        return _getRedeemStorage().activeRequest[tokenIn];
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function signatures(bytes32 digest) public view returns (bytes memory) {
        return _getRedeemStorage().signatures[digest];
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function signRequest(ILiquidLaneReactor.Request calldata request, bytes calldata signature)
        public
        onlyMyself
        returns (bytes32 digest)
    {
        // forgefmt: disable-next-item
        if (
            request.tokenIn == address(0) || request.amountIn == 0 || request.deadline < block.timestamp
        ) revert InvalidRequest();

        if (signature.length == 0) revert InvalidSignature();

        if (request.protocol != PROTOCOL) revert InvalidProtocol();

        if (request.outputs.length == 0) revert InvalidOutput();

        for (uint256 i; i < request.outputs.length; ++i) {
            // forgefmt: disable-next-item
            if (
                request.outputs[i].recipient != address(this) || request.outputs[i].amount == 0
            ) revert InvalidOutput();
        }
        RedeemStorage storage $ = _getRedeemStorage();
        if ($.activeRequest[request.tokenIn] != bytes32(0) || $.activeNonces[request.nonce]) revert ActiveRequest();

        if (ILiquidLaneReactor(REACTOR).isUsedNonce(address(this), request.nonce)) revert NonceUsed();

        digest = hashRequest(request);
        $.signatures[digest] = signature;
        $.authorizations[digest] = Authorization({
            tokenIn: request.tokenIn,
            reactor: REACTOR,
            protocol: PROTOCOL,
            chainId: block.chainid,
            nonce: request.nonce,
            deadline: request.deadline
        });
        $.activeRequest[request.tokenIn] = digest;
        $.activeNonces[request.nonce] = true;

        emit SignRequest(digest, request.tokenIn, request.nonce, request.amountIn, request.deadline, signature);
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function revokeRequest(bytes32 digest) public onlyMyself {
        RedeemStorage storage $ = _getRedeemStorage();
        Authorization storage authorization = $.authorizations[digest];
        if (authorization.tokenIn == address(0)) revert UnknownRequest();

        delete $.signatures[digest];
        ILiquidLaneReactor(authorization.reactor).invalidateNonce(authorization.nonce);

        emit RevokeRequest(digest);
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function finalizeRequest(bytes32 digest) public onlyMyself {
        RedeemStorage storage $ = _getRedeemStorage();
        Authorization storage authorization = $.authorizations[digest];
        if (authorization.tokenIn == address(0)) revert UnknownRequest();

        // forgefmt: disable-next-item
        if (
            $.signatures[digest].length != 0 && block.timestamp <= authorization.deadline
                && !ILiquidLaneReactor(authorization.reactor).isUsedNonce(address(this), authorization.nonce)
        ) revert RequestNotFinished();

        delete $.signatures[digest];
        delete $.activeRequest[authorization.tokenIn];
        delete $.activeNonces[authorization.nonce];
        delete $.authorizations[digest];

        emit FinalizeRequest(digest);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 digest, bytes calldata signature) public view returns (bytes4) {
        RedeemStorage storage $ = _getRedeemStorage();
        Authorization storage authorization = $.authorizations[digest];
        if (
            authorization.tokenIn == address(0) || signature.length == 0 || authorization.chainId != block.chainid
                || authorization.reactor != REACTOR || authorization.protocol != PROTOCOL
                || block.timestamp > authorization.deadline || keccak256(signature) != keccak256($.signatures[digest])
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

    /* INTERNAL FUNCTIONS */

    /// @dev Resolves the capability's ERC-7201 namespace within the calling adapter.
    function _getRedeemStorage() internal pure returns (RedeemStorage storage $) {
        assembly ("memory-safe") {
            $.slot := REDEEM_STORAGE_LOCATION
        }
    }
}
