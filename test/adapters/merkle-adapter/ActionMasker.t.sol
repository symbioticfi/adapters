// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {Test} from "forge-std/Test.sol";

contract ActionMaskerHarness {
    function mask(address target, uint96 value, bytes memory data, bytes memory dataMask)
        public
        pure
        returns (bytes32)
    {
        return ActionMasker.mask(target, value, data, dataMask);
    }

    function preserved(bytes memory data, bytes memory dataMask) public pure returns (bytes memory, bytes memory) {
        ActionMasker.mask(address(1), 0, data, dataMask);
        return (data, dataMask);
    }

    function dirtyPaddingLeaf(address target, uint96 value, bytes memory data, bytes memory dataMask)
        public
        pure
        returns (bytes32)
    {
        assembly ("memory-safe") {
            if mod(mload(data), 32) {
                mstore8(add(add(data, 32), mload(data)), 0xa5)
                mstore8(add(add(dataMask, 32), mload(dataMask)), 0x5a)
            }
        }
        return ActionMasker.mask(target, value, data, dataMask);
    }

    function aliasedLeaf(bytes memory data) public pure returns (bytes32) {
        return ActionMasker.mask(address(1), 0, data, data);
    }
}

contract ActionMaskerTest is Test {
    address internal _harness;

    function setUp() public {
        _harness = address(new ActionMaskerHarness());
    }

    function testFuzz_MatchesBytewiseReference(address target, uint96 value, bytes memory data, bytes32 seed)
        public
        view
    {
        bytes memory dataMask = new bytes(data.length);
        bytes memory masked = new bytes(data.length);
        for (uint256 i; i < data.length; ++i) {
            dataMask[i] = seed[i % 32];
            masked[i] = data[i] & ~dataMask[i];
        }
        assertEq(
            ActionMaskerHarness(_harness).mask(target, value, data, dataMask),
            keccak256(
                bytes.concat(
                    keccak256(
                        abi.encode(
                            target, value == 0 ? bytes1(0) : bytes1(0xff), keccak256(dataMask), keccak256(masked)
                        )
                    )
                )
            )
        );
        (bytes memory returnedData, bytes memory returnedMask) = ActionMaskerHarness(_harness).preserved(data, dataMask);
        assertEq(returnedData, data);
        assertEq(returnedMask, dataMask);
        assertEq(
            ActionMaskerHarness(_harness).dirtyPaddingLeaf(target, value, data, dataMask),
            ActionMaskerHarness(_harness).mask(target, value, data, dataMask)
        );
        assertEq(
            ActionMaskerHarness(_harness).aliasedLeaf(data),
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
    function test_Mask68BytesGas() public {
        ActionMaskerHarness(_harness).mask(address(this), 0, new bytes(68), new bytes(68));
        vm.snapshotGasLastCall("ActionMasker", "mask68");
    }

    /// forge-config: default.isolate = true
    function test_Mask1028BytesGas() public {
        ActionMaskerHarness(_harness).mask(address(this), 0, new bytes(1028), new bytes(1028));
        vm.snapshotGasLastCall("ActionMasker", "mask1028");
    }
}
