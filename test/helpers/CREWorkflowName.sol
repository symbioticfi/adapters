// SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// Matches Chainlink HashTruncateName: hex.EncodeToString(sha256(name))[:10].
function encodeWorkflowName(address oracle) pure returns (bytes10) {
    bytes32 hash = sha256(bytes(Strings.toHexString(oracle)));
    bytes memory alphabet = "0123456789abcdef";
    bytes memory encoded = new bytes(10);
    for (uint256 i; i < 5; ++i) {
        encoded[2 * i] = alphabet[uint8(hash[i]) >> 4];
        encoded[2 * i + 1] = alphabet[uint8(hash[i]) & 0xf];
    }
    return bytes10(encoded);
}
