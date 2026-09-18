#!/usr/bin/env python3
"""Rebuild leaf hashes and sorted-pair proofs using Foundry's independent ABI encoder."""

import argparse
from functools import lru_cache
import json
from pathlib import Path
import subprocess


def cast(*args):
    return subprocess.run(["cast", *args], check=True, capture_output=True, text=True).stdout.strip()


@lru_cache(maxsize=None)
def keccak(data):
    return cast("keccak", data)


def leaf_hash(leaf):
    data = bytes.fromhex(leaf["data"][2:])
    mask = bytes.fromhex(leaf["dataMask"][2:])
    if len(data) != len(mask):
        raise ValueError(f"Mismatched calldata and mask lengths: {leaf['id']}")
    value = int(leaf["value"])
    if not 0 <= value < 1 << 96:
        raise ValueError(f"value does not fit uint96: {leaf['id']}")
    masked = "0x" + bytes(a & ~b for a, b in zip(data, mask)).hex()
    encoded = cast(
        "abi-encode", "f(address,bytes1,bytes32,bytes32)", leaf["target"], "0x00" if value == 0 else "0xff",
        keccak(leaf["dataMask"]), keccak(masked),
    )
    return keccak(keccak(encoded))


def pair_hash(left, right):
    left, right = sorted((left, right))
    return keccak(left + right[2:])


def rebuild(fixture):
    leaves = fixture["leaves"]
    if not leaves:
        raise ValueError("The fixture must contain at least one leaf")
    for leaf in leaves:
        leaf.pop("role", None)
        leaf["hash"] = leaf_hash(leaf)
    leaves.sort(key=lambda leaf: leaf["hash"])

    # A complete binary tree stored as a heap, with sorted leaves filled from the end.
    # This is the layout used by OpenZeppelin's standard Merkle tree. Duplicate leaves
    # retain their fixture IDs and each receives a proof for its own position.
    tree = [None] * (2 * len(leaves) - 1)
    for i, leaf in enumerate(leaves):
        tree[len(tree) - 1 - i] = leaf["hash"]
    for i in range(len(leaves) - 2, -1, -1):
        tree[i] = pair_hash(tree[2 * i + 1], tree[2 * i + 2])
    for i, leaf in enumerate(leaves):
        position = len(tree) - 1 - i
        proof = []
        while position:
            proof.append(tree[position + 1 if position % 2 else position - 1])
            position = (position - 1) // 2
        leaf["proof"] = proof
    fixture["root"] = tree[0]
    fixture["leafCount"] = len(leaves)
    return fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", type=Path, default=Path("test/fixtures/merkle-tree.json"))
    parser.add_argument("--check", action="store_true", help="Fail if the committed fixture needs regeneration")
    args = parser.parse_args()
    original = args.path.read_text()
    rendered = json.dumps(rebuild(json.loads(original)), indent=4) + "\n"
    if args.check:
        if rendered != original:
            raise SystemExit(f"Fixture needs regeneration: {args.path}")
        print(f"Fixture matches: {args.path}")
    else:
        args.path.write_text(rendered)
        print(f"Updated fixture: {args.path}")


if __name__ == "__main__":
    main()
