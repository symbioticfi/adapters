// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {MerkleAdapterVerifier} from "../../../src/contracts/merkle_adapter/libraries/MerkleAdapterVerifier.sol";

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title TreeFixtureTest
/// @notice Differential test between the off-chain tree builder and `MerkleAdapterVerifier`.
/// @dev The fixture preserves the protocol action constraints exported from merkle-console. Every leaf
///      is encoded independently with Foundry cast, then re-derived here through the production library.
///      Regenerate hashes and proofs from the repository root with:
///        python3 script/utils/update_merkle_fixture.py
contract TreeFixtureTest is Test {
    using stdJson for string;

    struct Leaf {
        bytes data;
        bytes dataMask;
        uint96 value;
        bytes32 hash;
        bytes32[] proof;
        address target;
    }

    string internal json;
    bytes32 internal root;
    uint256 internal count;

    function setUp() public {
        json = vm.readFile("test/fixtures/merkle-tree.json");
        root = json.readBytes32(".root");
        count = json.readUint(".leafCount");
    }

    function _leaf(uint256 i) internal view returns (Leaf memory leaf) {
        string memory base = string.concat(".leaves[", vm.toString(i), "]");
        leaf.target = json.readAddress(string.concat(base, ".target"));
        leaf.value = uint96(vm.parseUint(json.readString(string.concat(base, ".value"))));
        leaf.data = json.readBytes(string.concat(base, ".data"));
        leaf.dataMask = json.readBytes(string.concat(base, ".dataMask"));
        leaf.hash = json.readBytes32(string.concat(base, ".hash"));
        leaf.proof = json.readBytes32Array(string.concat(base, ".proof"));
    }

    /// @dev Exposes the calldata-only library function to this contract's memory-held fixture data.
    function leafOf(address target, uint96 value, bytes calldata data, bytes calldata dataMask)
        external
        pure
        returns (bytes32)
    {
        return MerkleAdapterVerifier.leaf(target, value, data, dataMask);
    }

    /// @notice Every leaf hash the builder computed matches `MerkleAdapterVerifier.leaf()` exactly.
    function test_LeafEncodingMatchesVerifier() public view {
        assertGt(count, 0, "fixture is empty");

        for (uint256 i; i < count; ++i) {
            Leaf memory leaf = _leaf(i);
            bytes32 derived = this.leafOf(leaf.target, leaf.value, leaf.data, leaf.dataMask);
            assertEq(derived, leaf.hash, string.concat("leaf ", vm.toString(i), " encoding drift"));
        }
    }

    /// @notice Every proof the builder emitted verifies against the published root.
    function test_EveryProofVerifiesAgainstRoot() public view {
        for (uint256 i; i < count; ++i) {
            Leaf memory leaf = _leaf(i);
            assertTrue(
                MerkleProof.verify(leaf.proof, root, leaf.hash), string.concat("leaf ", vm.toString(i), " proof failed")
            );
        }
    }

    /// @notice A leaf from this tree does not verify against a different root.
    function test_ProofFailsAgainstWrongRoot() public view {
        Leaf memory leaf = _leaf(0);
        assertFalse(MerkleProof.verify(leaf.proof, bytes32(uint256(root) ^ 1), leaf.hash));
    }

    /// @notice The keeper substitutes real values into free calldata slots and reuses the same mask;
    ///         the leaf hash must be unchanged. This is the property the whole scheme rests on.
    function test_FreeSlotsCanCarryAnyValue() public {
        for (uint256 i; i < count; ++i) {
            Leaf memory leaf = _leaf(i);

            bytes memory live = leaf.data;
            bool mutated;
            // Flip every byte the mask leaves free — the execution-time degree of freedom.
            for (uint256 b; b < live.length; ++b) {
                if (leaf.dataMask[b] != 0xff) {
                    live[b] = bytes1(uint8(live[b]) ^ uint8(~uint8(leaf.dataMask[b])));
                    mutated = true;
                }
            }
            if (!mutated) continue;

            assertEq(
                this.leafOf(leaf.target, leaf.value, live, leaf.dataMask),
                leaf.hash,
                string.concat("leaf ", vm.toString(i), " changed when only free bits moved")
            );
        }
    }

    /// @notice Changing a byte the mask pins must change the leaf, for every leaf that pins anything.
    function test_PinnedBitsAreCommitted() public {
        for (uint256 i; i < count; ++i) {
            Leaf memory leaf = _leaf(i);

            bytes memory live = leaf.data;
            uint256 target = type(uint256).max;
            // Find a pinned byte that currently has a zero bit we can set, so the mutation is visible.
            for (uint256 b; b < live.length; ++b) {
                if (leaf.dataMask[b] == 0xff && live[b] != 0xff) {
                    target = b;
                    break;
                }
            }
            if (target == type(uint256).max) continue;

            live[target] = bytes1(uint8(live[target]) | ~uint8(live[target]));

            assertTrue(
                this.leafOf(leaf.target, leaf.value, live, leaf.dataMask) != leaf.hash,
                string.concat("leaf ", vm.toString(i), " ignored a pinned byte")
            );
        }
    }
}
