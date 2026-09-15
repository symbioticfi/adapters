// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {ILiquidLaneReactor} from "../../interfaces/merkle_adapter/ILiquidLaneReactor.sol";
import {ILiquidLaneRedeemCapability} from "../../interfaces/merkle_adapter/ILiquidLaneRedeemCapability.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title LiquidLaneRedeemCapability
/// @notice Adapter-bound consumer funding and stored ERC-1271 signatures for Liquid Lane Reactor requests.
contract LiquidLaneRedeemCapability is MigratableEntity, ILiquidLaneRedeemCapability {
    using SafeERC20 for IERC20;

    /// @dev Metadata needed to expire, revoke, and finalize a persisted signature.
    struct Authorization {
        address tokenIn;
        uint256 chainId;
        uint256 nonce;
        uint256 deadline;
    }

    /// @dev EIP-712 schema used by the Liquid Lane Reactor and RFQ API.
    bytes32 internal constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant _NAME_HASH = keccak256("Reactor");
    bytes32 internal constant _VERSION_HASH = keccak256("1");
    bytes32 internal constant _OUTPUT_TYPEHASH = keccak256("Output(address token,uint256 amount,address recipient)");
    bytes32 internal constant _REQUEST_TYPEHASH = keccak256(
        "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)"
        "Output(address token,uint256 amount,address recipient)"
    );

    /// @inheritdoc ILiquidLaneRedeemCapability
    address public adapter;

    /// @inheritdoc ILiquidLaneRedeemCapability
    address public immutable REACTOR;

    /// @inheritdoc ILiquidLaneRedeemCapability
    address public protocol;

    /// @inheritdoc ILiquidLaneRedeemCapability
    mapping(address tokenIn => bytes32 digest) public activeRequest;

    /// @inheritdoc ILiquidLaneRedeemCapability
    mapping(bytes32 digest => bytes signature) public signatures;

    /// @dev Requests remain tracked after fill or revocation until their funding is finalized.
    mapping(bytes32 digest => Authorization authorization) internal _authorizations;

    /// @dev Reactor nonces are owned by the capability across all input tokens.
    mapping(uint256 nonce => bool active) internal _activeNonces;

    /// @dev Prevents a migration from changing the Reactor behind existing signatures and approvals.
    address internal _initialReactor;

    /// @dev Restricts funding and signature controls to Merkle-authorized adapter calls.
    modifier onlyAdapter() {
        if (msg.sender != adapter) {
            revert InvalidCaller();
        }
        _;
    }

    /// @dev Binds the implementation to its factory and Liquid Lane Reactor.
    constructor(address factory, address reactor) MigratableEntity(factory) {
        if (reactor.code.length == 0) {
            revert InvalidReactor();
        }
        REACTOR = reactor;
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function signRequest(ILiquidLaneReactor.Request calldata request, bytes calldata signature)
        external
        nonReentrant
        onlyAdapter
        returns (bytes32 digest)
    {
        if (
            request.tokenIn == address(0) || request.amountIn == 0 || request.amountIn == type(uint256).max
                || request.deadline < block.timestamp
        ) {
            revert InvalidRequest();
        }
        if (signature.length == 0) {
            revert InvalidSignature();
        }
        if (request.protocol != protocol) {
            revert InvalidProtocol();
        }
        if (request.outputs.length == 0) {
            revert InvalidOutput();
        }
        for (uint256 i; i < request.outputs.length; ++i) {
            if (request.outputs[i].recipient != adapter || request.outputs[i].amount == 0) {
                revert InvalidOutput();
            }
        }
        if (activeRequest[request.tokenIn] != bytes32(0) || _activeNonces[request.nonce]) {
            revert ActiveRequest();
        }
        if (ILiquidLaneReactor(REACTOR).isUsedNonce(address(this), request.nonce)) {
            revert NonceUsed();
        }

        IERC20 token = IERC20(request.tokenIn);
        uint256 previousBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), request.amountIn);
        if (token.balanceOf(address(this)) != previousBalance + request.amountIn) {
            revert InvalidFunding();
        }
        token.forceApprove(REACTOR, request.amountIn);

        // Publish the signature only after the exact input and allowance are available for settlement.
        digest = hashRequest(request);
        signatures[digest] = signature;
        _authorizations[digest] = Authorization({
            tokenIn: request.tokenIn, chainId: block.chainid, nonce: request.nonce, deadline: request.deadline
        });
        activeRequest[request.tokenIn] = digest;
        _activeNonces[request.nonce] = true;

        emit SignRequest(digest, request.tokenIn, request.nonce, request.amountIn, request.deadline, signature);
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function revokeRequest(bytes32 digest) external nonReentrant onlyAdapter {
        Authorization storage authorization = _authorizations[digest];
        if (authorization.tokenIn == address(0)) {
            revert UnknownRequest();
        }
        delete signatures[digest];
        ILiquidLaneReactor(REACTOR).invalidateNonce(authorization.nonce);

        emit RevokeRequest(digest);
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function finalizeRequest(bytes32 digest) external nonReentrant onlyAdapter returns (uint256 returnedAmount) {
        Authorization storage authorization = _authorizations[digest];
        address tokenIn = authorization.tokenIn;
        if (tokenIn == address(0)) {
            revert UnknownRequest();
        }
        uint256 nonce = authorization.nonce;
        if (
            signatures[digest].length != 0 && block.timestamp <= authorization.deadline
                && !ILiquidLaneReactor(REACTOR).isUsedNonce(address(this), nonce)
        ) {
            revert RequestNotFinished();
        }

        delete signatures[digest];
        delete _authorizations[digest];
        delete activeRequest[tokenIn];
        delete _activeNonces[nonce];

        IERC20 token = IERC20(tokenIn);
        token.forceApprove(REACTOR, 0);
        returnedAmount = token.balanceOf(address(this));
        if (returnedAmount != 0) {
            token.safeTransfer(adapter, returnedAmount);
        }

        emit FinalizeRequest(digest, returnedAmount);
    }

    /// @inheritdoc ILiquidLaneRedeemCapability
    function hashRequest(ILiquidLaneReactor.Request calldata request) public view returns (bytes32 digest) {
        bytes32[] memory outputHashes = new bytes32[](request.outputs.length);
        for (uint256 i; i < request.outputs.length; ++i) {
            outputHashes[i] = keccak256(abi.encode(_OUTPUT_TYPEHASH, request.outputs[i]));
        }
        bytes32 structHash = keccak256(
            abi.encode(
                _REQUEST_TYPEHASH,
                request.tokenIn,
                request.amountIn,
                keccak256(abi.encodePacked(outputHashes)),
                request.deadline,
                request.nonce,
                request.protocol
            )
        );
        bytes32 domainSeparator =
            keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, REACTOR));
        digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    /// @inheritdoc IERC1271
    /// @dev Accepts only the saved bytes for a live Request on the original chain with an unused Reactor nonce.
    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        Authorization storage authorization = _authorizations[digest];
        if (
            authorization.tokenIn == address(0) || signature.length == 0 || authorization.chainId != block.chainid
                || block.timestamp > authorization.deadline || keccak256(signature) != keccak256(signatures[digest])
                || ILiquidLaneReactor(REACTOR).isUsedNonce(address(this), authorization.nonce)
        ) {
            return 0xffffffff;
        }
        return IERC1271.isValidSignature.selector;
    }

    /// @dev Initializes the adapter and required protocol signer of the capability proxy.
    function _initialize(uint64, address, bytes memory data) internal override {
        (address adapter_, address protocol_) = abi.decode(data, (address, address));
        if (adapter_ == address(0)) {
            revert InvalidAdapter();
        }
        if (protocol_ == address(0)) {
            revert InvalidProtocol();
        }
        adapter = adapter_;
        protocol = protocol_;
        _initialReactor = REACTOR;
    }

    /// @dev Allows state-preserving upgrades while retaining the Reactor bound to existing request funding.
    function _migrate(uint64, uint64, bytes calldata data) internal view override {
        if (data.length != 0) {
            revert InvalidMigrationData();
        }
        if (_initialReactor != REACTOR) {
            revert InvalidReactor();
        }
    }
}
