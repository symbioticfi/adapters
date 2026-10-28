// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";

/// @title UpstreamArtifacts
/// @notice Script-only deployment of pinned upstream creation code and linked libraries.
abstract contract UpstreamArtifacts is Script {
    error ArtifactDeploymentFailed();
    error InvalidLibraryLink();

    mapping(bytes32 identifier => address deployed) internal _libraries;

    function _deployArtifact(string memory profile, string memory name, bytes memory constructorArgs)
        internal
        returns (address deployed)
    {
        string[] memory command = new string[](4);
        command[0] = "python3";
        command[1] = "script/deploy/testnet/upstream/artifact.py";
        command[2] = profile;
        command[3] = name;
        (bytes memory code, string[] memory names, uint256[] memory offsets) =
            abi.decode(vm.ffi(command), (bytes, string[], uint256[]));
        if (names.length != offsets.length) revert InvalidLibraryLink();
        for (uint256 i; i < names.length; ++i) {
            bytes32 key = keccak256(abi.encode(profile, names[i]));
            address libraryAddress = _libraries[key];
            if (libraryAddress == address(0)) {
                libraryAddress = _deployArtifact(profile, names[i], "");
                _libraries[key] = libraryAddress;
            }
            if (offsets[i] + 20 > code.length) revert InvalidLibraryLink();
            bytes20 replacement = bytes20(libraryAddress);
            for (uint256 j; j < 20; ++j) {
                code[offsets[i] + j] = replacement[j];
            }
        }
        bytes memory creationCode = bytes.concat(code, constructorArgs);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 32), mload(creationCode))
        }
        if (deployed == address(0)) revert ArtifactDeploymentFailed();
    }
}
