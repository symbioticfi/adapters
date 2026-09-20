// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMerkleAdapter} from "../IMerkleAdapter.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title IMerkleAccount
 * @notice Interface for strategy custody and execution authorized by a MerkleAdapter.
 */
interface IMerkleAccount is IERC1271 {
    /* ERRORS */

    /**
     * @notice Raised when execution is not requested by the adapter or a signature change is not a self-call.
     */
    error InvalidCaller();

    /**
     * @notice Raised when a Liquid Lane signature does not encode exactly one output.
     */
    error InvalidSignature();

    /**
     * @notice Raised when no capability handles the calldata, including incomplete function selectors.
     */
    error UnknownSelector();

    /* EVENTS */

    /**
     * @notice Emitted when the EIP-712 digest of the supplied fields is approved.
     * @param digest Protocol-specific message hash.
     * @param signature Encoded typed structure whose digest was approved.
     */
    event SetSignature(bytes32 indexed digest, bytes signature);

    /**
     * @notice Emitted when a stored digest approval is revoked.
     * @param digest Revoked message hash.
     */
    event RevokeSignature(bytes32 indexed digest);

    /* FUNCTIONS */

    /**
     * @notice Returns the adapter that verifies permissions and holds vault reserves.
     * @return adapter_ Adapter that created this account and is its only execution authority.
     */
    function adapter() external view returns (address adapter_);

    /**
     * @notice Executes calls from the account after its adapter verifies permissions.
     * @dev Only the adapter may call. Capabilities delegate into this account and resolve selectors from the adapter.
     * @param actions Merkle actions already checked by the adapter; proofs and masks are not reverified here.
     * @return results Return data for each action.
     */
    function execute(IMerkleAdapter.Action[] calldata actions) external returns (bytes[] memory results);

    /**
     * @notice Returns whether a digest has an active ERC-1271 approval.
     * @param digest Protocol-specific message hash.
     * @return approved Whether the digest is approved.
     */
    function signatures(bytes32 digest) external view returns (bool approved);

    /**
     * @notice Approves an EIP-712 message through a Merkle-authorized account self-call.
     * @dev The account computes the digest; callers cannot supply an independent message hash.
     * Ordinarily signature is abi.encode(typeHash, field1, ...), with EIP-712 dynamic fields hashed.
     * Liquid Lane REQUEST_TYPEHASH instead uses exactly nine words: typeHash, tokenIn, amountIn,
     * outputToken, minimumOutput, recipient, deadline, nonce, protocol. The account hashes the single
     * output into the Reactor's Output[] field. Additional outputs and prehashed outputs are unsupported.
     * Leaves must fix the domain, type hash, tokens, recipient, protocol, ABI layout and all other
     * restricted fields; only intended runtime fields may vary. No validator or capability is needed.
     * ERC-1271 checks the stored digest only and ignores its signature bytes; protocols may pass empty bytes.
     * Expiry, nonce use and settlement conditions are enforced by the consuming protocol.
     * Root or role changes do not revoke saved approvals; use revokeSignature explicitly.
     * Deferred settlement can spend only account-held assets; vault reserves remain on the adapter.
     * @param domain EIP-712 domain separator committed by the permission leaf.
     * @param signature Encoded typed structure, beginning with its type hash.
     */
    function setSignature(bytes32 domain, bytes calldata signature) external;

    /**
     * @notice Revokes one digest through a Merkle-authorized account self-call.
     * @param digest Previously approved EIP-712 message hash.
     */
    function revokeSignature(bytes32 digest) external;
}
