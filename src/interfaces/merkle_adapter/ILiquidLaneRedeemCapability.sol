// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ILiquidLaneReactor} from "./ILiquidLaneReactor.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title ILiquidLaneRedeemCapability
 * @notice Interface for adapter-routed ERC-1271 signing for Liquid Lane consumer requests.
 */
interface ILiquidLaneRedeemCapability is IERC1271 {
    /* ERRORS */

    /**
     * @notice Raised when a token or nonce already has a signed request awaiting finalization.
     */
    error ActiveRequest();

    /**
     * @notice Raised when a signature mutation is not called by the adapter itself.
     */
    error InvalidCaller();

    /**
     * @notice Raised when a request has no positive output, or an output recipient is not the adapter.
     */
    error InvalidOutput();

    /**
     * @notice Raised when the protocol is zero or a request binds a different protocol.
     */
    error InvalidProtocol();

    /**
     * @notice Raised when the bound Reactor has no code.
     */
    error InvalidReactor();

    /**
     * @notice Raised when the input token or amount is invalid, or the request has expired.
     */
    error InvalidRequest();

    /**
     * @notice Raised when a supplied signature is empty.
     */
    error InvalidSignature();

    /**
     * @notice Raised when the request's consumer nonce has already been consumed.
     */
    error NonceUsed();

    /**
     * @notice Raised when a live request must first be revoked before clearing its metadata.
     */
    error RequestNotFinished();

    /**
     * @notice Raised when a digest does not identify a signed request.
     */
    error UnknownRequest();

    /* EVENTS */

    /**
     * @notice Emitted when a request is authorized with its exact signature.
     * @param digest Reactor EIP-712 request digest.
     * @param tokenIn Signed input token.
     * @param nonce Reactor nonce owned by the adapter.
     * @param amountIn Exact signed input amount.
     * @param deadline Request expiry timestamp.
     * @param signature Exact signature bytes accepted through ERC-1271.
     */
    event SignRequest(
        bytes32 indexed digest,
        address indexed tokenIn,
        uint256 indexed nonce,
        uint256 amountIn,
        uint256 deadline,
        bytes signature
    );

    /**
     * @notice Emitted when a signature is revoked and its Reactor nonce is invalidated.
     * @param digest Revoked request digest.
     */
    event RevokeRequest(bytes32 indexed digest);

    /**
     * @notice Emitted when a finished request's signature metadata is cleared.
     * @param digest Finalized request digest.
     */
    event FinalizeRequest(bytes32 indexed digest);

    /* FUNCTIONS */

    /**
     * @notice Returns the fixed Reactor that pulls input tokens and verifies request signatures.
     * @return reactor Bound Reactor address.
     */
    function REACTOR() external view returns (address reactor);

    /**
     * @notice Returns the protocol signer required in every request.
     * @return newProtocol Configured Liquid Lane protocol signer.
     */
    function PROTOCOL() external view returns (address newProtocol);

    /**
     * @notice Returns the signed request awaiting finalization for an input token.
     * @param tokenIn Input token address.
     * @return digest Active digest, or zero when the token has no active request.
     */
    function activeRequest(address tokenIn) external view returns (bytes32 digest);

    /**
     * @notice Returns the exact persisted signature for a request.
     * @param digest Reactor EIP-712 request digest.
     * @return signature Saved signature, or empty when absent or revoked.
     */
    function signatures(bytes32 digest) external view returns (bytes memory signature);

    /**
     * @notice Returns the Reactor Request EIP-712 digest for the current chain and bound Reactor.
     * @param request Request to hash, without authorization or funding side effects.
     * @return digest Full EIP-712 digest accepted by the Reactor.
     */
    function hashRequest(ILiquidLaneReactor.Request calldata request) external view returns (bytes32 digest);

    /**
     * @notice Saves the exact signature used by the Liquid Lane API and Reactor.
     * @dev Call through an authorized Merkle self-call. The adapter is both the swapper and every
     * output recipient. Tokens remain on the adapter; the curator configures Reactor allowances
     * separately with ERC-20 approve actions. Signing neither checks funding nor changes allowances.
     * Only one request per input token or nonce may await finalization.
     * @param request Exact-input request with positive outputs sent to the adapter.
     * @param signature Nonempty signature bytes accepted through ERC-1271.
     * @return digest Saved Reactor EIP-712 request digest.
     */
    function signRequest(ILiquidLaneReactor.Request calldata request, bytes calldata signature)
        external
        returns (bytes32 digest);

    /**
     * @notice Revokes a signature and permanently invalidates its original Reactor nonce.
     * @dev Requires an authorized Merkle self-call; never calls the token or modifies allowances.
     * @param digest Request digest to revoke.
     */
    function revokeRequest(bytes32 digest) external;

    /**
     * @notice Clears a filled, revoked, or expired request's signature metadata.
     * @dev Requires an authorized Merkle self-call. Tokens and allowances remain untouched.
     * Outstanding requests may stay stored until the curator decides to finalize them.
     * @param digest Finished request digest.
     */
    function finalizeRequest(bytes32 digest) external;
}

/**
 * @title ILiquidLaneRedeemCapabilityConstants
 * @notice Base contract defining constants for LiquidLaneRedeemCapability.
 */
abstract contract ILiquidLaneRedeemCapabilityConstants {
    /* CONSTANTS */

    /**
     * @dev ERC-7201 namespace for symbiotic.storage.LiquidLaneRedeemCapability.
     */
    bytes32 internal constant REDEEM_STORAGE_LOCATION =
        0x4fe893ee3d5507262d3fa46ac0b3202265dbeb5f49c84de2df615d9340d0c600;

    /**
     * @dev EIP-712 schema used by the Liquid Lane Reactor and RFQ API.
     */
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant NAME_HASH = keccak256("Reactor");

    bytes32 internal constant VERSION_HASH = keccak256("1");

    bytes32 internal constant OUTPUT_TYPEHASH = keccak256("Output(address token,uint256 amount,address recipient)");

    bytes32 internal constant REQUEST_TYPEHASH = keccak256(
        "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)"
        "Output(address token,uint256 amount,address recipient)"
    );
}
