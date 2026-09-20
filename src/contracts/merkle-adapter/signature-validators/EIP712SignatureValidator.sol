// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    IEIP712SignatureValidator
} from "../../../interfaces/merkle-adapter/signature-validators/IEIP712SignatureValidator.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title EIP712SignatureValidator
/// @notice Contract for validating Merkle-approved EIP-712 preimages.
/// @custom:security-contact https://github.com/symbioticfi/adapters/security
contract EIP712SignatureValidator is IEIP712SignatureValidator {
    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IEIP712SignatureValidator
    function isValidSignature(bytes32 digest, bytes calldata signature) public pure returns (bytes4) {
        (bytes32 domainSeparator, bytes memory encodedStruct) = abi.decode(signature, (bytes32, bytes));
        return digest == MessageHashUtils.toTypedDataHash(domainSeparator, keccak256(encodedStruct))
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}
