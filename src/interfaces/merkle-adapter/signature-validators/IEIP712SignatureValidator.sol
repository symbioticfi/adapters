// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title IEIP712SignatureValidator
 * @notice Interface for stateless EIP-712 preimage validation.
 * @dev Authorization belongs to the calling adapter's Merkle-controlled setSignature. Its leaf must
 * pin this validator, the domain, type hash, constrained fields and ABI layout. Dynamic or nested
 * fields represented by hashes remain opaque; this validator does not enforce their preimages.
 */
interface IEIP712SignatureValidator is IERC1271 {
    /* FUNCTIONS */

    /**
     * @notice Returns the ERC-1271 magic value when the approved preimage produces the supplied digest.
     * @dev Does not authorize signatures on its own. Malformed encoding reverts, which the adapter
     * treats as an invalid signature. No protocol policy, expiry or balance checks are performed here.
     * @param digest Expected EIP-712 digest.
     * @param signature ABI-encoded (bytes32 domainSeparator, bytes encodedStruct), where encodedStruct
     * is the EIP-712 type hash followed by encodeData, not an ABI-encoded dynamic tuple or a struct hash.
     * @return magicValue ERC-1271 magic value, or 0xffffffff if the digest differs.
     */
    function isValidSignature(bytes32 digest, bytes calldata signature) external pure returns (bytes4 magicValue);
}
