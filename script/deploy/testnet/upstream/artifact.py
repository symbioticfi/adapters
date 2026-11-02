"""Return checked upstream creation code and its library slots as an ABI tuple."""

import argparse
import hashlib
import json
import os
from pathlib import Path


PINS = Path(__file__).with_name("pins.json")
DEFAULT_CACHE = Path(__file__).resolve().parents[4] / "cache" / "testnet-upstream"


def load_artifact(root, descriptor, identifier):
    stamp = json.loads((root / ".merkle-artifacts.json").read_text())
    if stamp["descriptor"] != descriptor:
        raise ValueError("prepared build does not match pinned upstream descriptor; run prepare.py")
    source, separator, name = identifier.rpartition(":")
    if not separator:
        name = identifier
    if not name or "/" in name or "\\" in name or name in {".", ".."}:
        raise ValueError("invalid artifact identifier")
    matches = []
    for relative, checksum in stamp["artifacts"].items():
        path = root / relative
        if path.name != name + ".json":
            continue
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError("artifact outside prepared build")
        if hashlib.sha256(path.read_bytes()).hexdigest() != checksum:
            raise ValueError("artifact checksum mismatch")
        artifact = json.loads(path.read_text())
        metadata = artifact.get("metadata", {})
        if isinstance(metadata, str):
            metadata = json.loads(metadata)
        targets = metadata.get("settings", {}).get("compilationTarget", {})
        if not separator or targets.get(source) == name:
            matches.append(artifact)
    if len(matches) != 1:
        raise ValueError(f"expected exactly one artifact for {identifier}, found {len(matches)}")
    bytecode = matches[0]["bytecode"]
    code = bytecode["object"].removeprefix("0x")
    if not code:
        raise ValueError("empty creation bytecode")
    names, offsets, used = [], [], set()
    for source, libraries in sorted(bytecode.get("linkReferences", {}).items()):
        for name, references in sorted(libraries.items()):
            for link in references:
                start, length = link["start"], link["length"]
                if length != 20 or start < 0 or (start + length) * 2 > len(code):
                    raise ValueError("invalid library link")
                slots = set(range(start, start + length))
                if used & slots:
                    raise ValueError("overlapping library links")
                used |= slots
                code = code[: start * 2] + "00" * length + code[(start + length) * 2 :]
                names.append(source + ":" + name)
                offsets.append(start)
    try:
        creation_code = bytes.fromhex(code)
    except ValueError as exc:
        raise ValueError("unresolved creation bytecode") from exc
    return creation_code, names, offsets


def word(number):
    return number.to_bytes(32, "big")


def dynamic_bytes(value):
    return word(len(value)) + value + bytes(-len(value) % 32)


def encode_artifact(code, names, offsets):
    encoded_code = dynamic_bytes(code)
    strings = [dynamic_bytes(name.encode()) for name in names]
    cursor = 32 * len(names)
    pointers = []
    for value in strings:
        pointers.append(word(cursor))
        cursor += len(value)
    encoded_names = word(len(names)) + b"".join(pointers + strings)
    encoded_offsets = word(len(offsets)) + b"".join(word(offset) for offset in offsets)
    return (
        word(96) + word(96 + len(encoded_code)) + word(96 + len(encoded_code) + len(encoded_names))
        + encoded_code + encoded_names + encoded_offsets
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile")
    parser.add_argument("contract")
    args = parser.parse_args()
    descriptor = json.loads(PINS.read_text())[args.profile]
    cache = Path(os.environ.get("UPSTREAM_CACHE_DIR", DEFAULT_CACHE))
    print("0x" + encode_artifact(*load_artifact(cache / args.profile, descriptor, args.contract)).hex())


if __name__ == "__main__":
    main()
