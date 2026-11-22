// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Shared CREATE3 address derivation for per-vault automation authority.
library VaultAccessManagerAddress {
    address internal constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    address internal constant MAINNET_DEPLOYER = 0xc2bf048aa3BCF7F7567e36468041AF2a945E614D;
    bytes32 internal constant CREATE3_PROXY_HASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    /// @dev CreateX's protected format: sender (20), cross-chain flag (1), vault hash (11).
    function salt(address vault, address deployer) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(deployer, bytes1(0), bytes11(keccak256(abi.encode(vault)))));
    }

    function predict(address vault, address deployer) internal pure returns (address) {
        bytes32 guardedSalt = keccak256(abi.encode(bytes32(uint256(uint160(deployer))), salt(vault, deployer)));
        address proxy = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE_X, guardedSalt, CREATE3_PROXY_HASH))))
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }
}
