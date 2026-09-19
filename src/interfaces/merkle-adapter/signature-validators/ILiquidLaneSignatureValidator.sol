// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ILiquidLaneReactor} from "../capabilities/ILiquidLaneReactor.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title ILiquidLaneSignatureValidator
 * @notice Interface for stateless Liquid Lane consumer signature validation.
 */
interface ILiquidLaneSignatureValidator is IERC1271 {
    /* FUNCTIONS */

    /**
     * @notice Returns the Reactor whose EIP-712 domain and consumer nonces are checked.
     * @return reactor Bound Reactor address.
     */
    function REACTOR() external view returns (address reactor);

    /**
     * @notice Returns the protocol signer required by validated requests.
     * @return protocol Bound protocol signer.
     */
    function PROTOCOL() external view returns (address protocol);

    /**
     * @notice Returns the request's EIP-712 digest for the current chain and bound Reactor.
     * @param request Liquid Lane request to hash.
     * @return digest Complete Reactor request digest.
     */
    function hashRequest(ILiquidLaneReactor.Request memory request) external view returns (bytes32 digest);

    /**
     * @notice Returns the ERC-1271 magic value for a valid request owned by the calling adapter.
     * @dev The adapter must separately authorize the exact validator and encoded request through its
     * Merkle-controlled setSignature function. This stateless validator only checks the request policy,
     * digest, deadline and Reactor nonce; calling it directly does not authorize adapter spending.
     * Malformed request encoding reverts and is treated as invalid by the adapter's signature checker.
     * @param digest Expected Reactor request digest.
     * @param signature ABI-encoded ILiquidLaneReactor.Request, without the adapter's validator envelope.
     * @return magicValue ERC-1271 magic value, or 0xffffffff for an invalid request.
     */
    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4 magicValue);
}

/**
 * @title ILiquidLaneSignatureValidatorConstants
 * @notice Base contract defining the Liquid Lane Reactor's EIP-712 schema.
 */
abstract contract ILiquidLaneSignatureValidatorConstants {
    /* CONSTANTS */

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
