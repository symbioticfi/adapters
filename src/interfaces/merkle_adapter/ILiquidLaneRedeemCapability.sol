// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ILiquidLaneReactor} from "./ILiquidLaneReactor.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/**
 * @title ILiquidLaneRedeemCapability
 * @notice Interface for adapter-controlled funding and ERC-1271 signing for Liquid Lane consumer requests.
 */
interface ILiquidLaneRedeemCapability is IMigratableEntity, IERC1271 {
    /* ERRORS */

    /**
     * @notice Raised when a token or nonce already has a funded request awaiting finalization.
     */
    error ActiveRequest();

    /**
     * @notice Raised when the configured adapter is zero.
     */
    error InvalidAdapter();

    /**
     * @notice Raised when a function is not called by the bound adapter.
     */
    error InvalidCaller();

    /**
     * @notice Raised when funding delivers a different amount from the signed exact input.
     */
    error InvalidFunding();

    /**
     * @notice Raised when migration data is not supported by this implementation.
     */
    error InvalidMigrationData();

    /**
     * @notice Raised when a request has no positive output, or an output recipient is not the adapter.
     */
    error InvalidOutput();

    /**
     * @notice Raised when the configured protocol is zero or a request binds a different protocol.
     */
    error InvalidProtocol();

    /**
     * @notice Raised when the bound Reactor has no code, or a migration changes the Reactor.
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
     * @notice Raised when a live request must first be revoked before reclaiming its funding.
     */
    error RequestNotFinished();

    /**
     * @notice Raised when a digest does not identify a funded request.
     */
    error UnknownRequest();

    /* EVENTS */

    /**
     * @notice Emitted when a request is funded and its exact signature is authorized.
     * @param digest Reactor EIP-712 request digest.
     * @param tokenIn Funded input token.
     * @param nonce Reactor nonce owned by this capability.
     * @param amountIn Exact funded input amount.
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
     * @notice Emitted when finished-request funding and allowance are cleared.
     * @param digest Finalized request digest.
     * @param returnedAmount Remaining input balance returned to the adapter.
     */
    event FinalizeRequest(bytes32 indexed digest, uint256 returnedAmount);

    /* FUNCTIONS */

    /**
     * @notice Returns the only adapter authorized to sign, fund, revoke, and finalize requests.
     * @return newAdapter Bound adapter address.
     */
    function adapter() external view returns (address newAdapter);

    /**
     * @notice Returns the fixed Reactor that pulls input tokens and verifies request signatures.
     * @return reactor Bound Reactor address.
     */
    function REACTOR() external view returns (address reactor);

    /**
     * @notice Returns the protocol signer required in every request.
     * @return newProtocol Configured Liquid Lane protocol signer.
     */
    function protocol() external view returns (address newProtocol);

    /**
     * @notice Returns the funded request awaiting finalization for an input token.
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
     * @notice Funds a concrete request and saves the signature used by the Liquid Lane API and Reactor.
     * @dev The API quote must use this capability as swapper and the adapter as every output recipient.
     * Pulls exactly `amountIn` from the adapter and approves exactly that amount to Reactor.
     * Only one request per input token or nonce may await finalization. The maximum uint256 amount is rejected
     * because ERC-20 implementations may treat that approval as an unlimited allowance.
     * @param request Exact-input request with positive outputs sent to the adapter.
     * @param signature Nonempty signature bytes to authorize by exact matching through ERC-1271.
     * @return digest Saved Reactor EIP-712 request digest.
     */
    function signRequest(ILiquidLaneReactor.Request calldata request, bytes calldata signature)
        external
        returns (bytes32 digest);

    /**
     * @notice Revokes a signature and permanently invalidates its Reactor nonce.
     * @dev Does not call the input token, so paused transfers or approvals cannot block cancellation.
     * Call `finalizeRequest` separately to reset approval and recover remaining funding.
     * @param digest Request digest to revoke.
     */
    function revokeRequest(bytes32 digest) external;

    /**
     * @notice Clears a filled, revoked, or expired request and returns its remaining input balance.
     * @dev Resets the Reactor approval before returning the token balance, including unsolicited transfers.
     * Settlement outputs are delivered directly to the adapter by the Reactor.
     * @param digest Finished request digest.
     * @return returnedAmount Remaining input balance returned to the adapter.
     */
    function finalizeRequest(bytes32 digest) external returns (uint256 returnedAmount);
}

/**
 * @title ILiquidLaneRedeemCapabilityConstants
 * @notice Base contract defining constants for LiquidLaneRedeemCapability.
 */
abstract contract ILiquidLaneRedeemCapabilityConstants {
    /* CONSTANTS */

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
