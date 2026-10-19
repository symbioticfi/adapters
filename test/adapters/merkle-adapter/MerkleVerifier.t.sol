// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {Test} from "forge-std/Test.sol";

contract MerkleVerifierHarness {
    function leaf(address target, uint96 value, bytes memory data, bytes memory mask) public pure returns (bytes32) {
        return MerkleAdapterVerifier.leaf(target, value, data, mask);
    }

    function preserved(bytes memory data, bytes memory mask) public pure returns (bytes memory, bytes memory) {
        MerkleAdapterVerifier.leaf(address(1), 0, data, mask);
        return (data, mask);
    }

    function dirtyPaddingLeaf(address target, uint96 value, bytes memory data, bytes memory mask)
        public
        pure
        returns (bytes32)
    {
        assembly ("memory-safe") {
            if mod(mload(data), 32) {
                mstore8(add(add(data, 32), mload(data)), 0xa5)
                mstore8(add(add(mask, 32), mload(mask)), 0x5a)
            }
        }
        return MerkleAdapterVerifier.leaf(target, value, data, mask);
    }

    function aliasedLeaf(bytes memory data) public pure returns (bytes32) {
        return MerkleAdapterVerifier.leaf(address(1), 0, data, data);
    }
}

contract MerkleVerifierTest is Test {
    address internal _harness;

    function setUp() public {
        _harness = address(new MerkleVerifierHarness());
    }

    function testFuzz_MatchesBytewiseReference(address target, uint96 value, bytes memory data, bytes32 seed)
        public
        view
    {
        bytes memory mask = new bytes(data.length);
        bytes memory masked = new bytes(data.length);
        for (uint256 i; i < data.length; ++i) {
            mask[i] = seed[i % 32];
            masked[i] = data[i] & ~mask[i];
        }
        assertEq(
            MerkleVerifierHarness(_harness).leaf(target, value, data, mask),
            keccak256(
                bytes.concat(
                    keccak256(
                        abi.encode(target, value == 0 ? bytes1(0) : bytes1(0xff), keccak256(mask), keccak256(masked))
                    )
                )
            )
        );
        (bytes memory returnedData, bytes memory returnedMask) = MerkleVerifierHarness(_harness).preserved(data, mask);
        assertEq(returnedData, data);
        assertEq(returnedMask, mask);
        assertEq(
            MerkleVerifierHarness(_harness).dirtyPaddingLeaf(target, value, data, mask),
            MerkleVerifierHarness(_harness).leaf(target, value, data, mask)
        );
        assertEq(
            MerkleVerifierHarness(_harness).aliasedLeaf(data),
            keccak256(
                bytes.concat(
                    keccak256(abi.encode(address(1), bytes1(0), keccak256(data), keccak256(new bytes(data.length))))
                )
            )
        );
    }

    function test_WordBoundaries() public view {
        uint256[9] memory lengths = [uint256(0), 1, 4, 31, 32, 33, 63, 64, 65];
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory data = new bytes(lengths[i]);
            for (uint256 j; j < data.length; ++j) {
                data[j] = bytes1(uint8(j + 1));
            }
            testFuzz_MatchesBytewiseReference(address(this), 1, data, keccak256("partial bit mask"));
        }
    }

    /// forge-config: default.isolate = true
    function test_Leaf68BytesGas() public {
        MerkleVerifierHarness(_harness).leaf(address(this), 0, new bytes(68), new bytes(68));
        vm.snapshotGasLastCall("MerkleVerifier", "leaf68");
    }

    /// forge-config: default.isolate = true
    function test_Leaf1028BytesGas() public {
        MerkleVerifierHarness(_harness).leaf(address(this), 0, new bytes(1028), new bytes(1028));
        vm.snapshotGasLastCall("MerkleVerifier", "leaf1028");
    }
}
