import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from artifact import load_artifact, encode_artifact


class ArtifactsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.descriptor = {"repository": "https://github.com/example/protocol", "commit": "a" * 40}
        self.path = self.root / "out" / "Example.sol" / "Example.json"
        self.path.parent.mkdir(parents=True)
        self.artifact = {
            "bytecode": {
                "object": "0x60" + "__$" + "a" * 34 + "$__" + "00",
                "linkReferences": {"src/Math.sol": {"Math": [{"start": 1, "length": 20}]}},
            },
            "metadata": {"settings": {"compilationTarget": {"src/Example.sol": "Example"}}},
        }
        self.save()

    def save(self):
        self.path.write_text(json.dumps(self.artifact))
        (self.root / ".merkle-artifacts.json").write_text(json.dumps({
            "descriptor": self.descriptor,
            "artifacts": {str(self.path.relative_to(self.root)): hashlib.sha256(self.path.read_bytes()).hexdigest()},
        }))

    def test_linked_artifact_zeroes_only_library_slots(self):
        code, names, offsets = load_artifact(self.root, self.descriptor, "src/Example.sol:Example")
        self.assertEqual(code, bytes.fromhex("60" + "00" * 20 + "00"))
        self.assertEqual(names, ["src/Math.sol:Math"])
        self.assertEqual(offsets, [1])
        encoded = encode_artifact(code, names, offsets)
        self.assertEqual(len(encoded) % 32, 0)
        self.assertEqual(int.from_bytes(encoded[:32], "big"), 96)

    def test_rejects_other_build_pin(self):
        with self.assertRaisesRegex(ValueError, "prepared build does not match"):
            load_artifact(self.root, {**self.descriptor, "commit": "b" * 40}, "Example")

    def test_rejects_modified_artifact(self):
        self.path.write_text("{}")
        with self.assertRaisesRegex(ValueError, "artifact checksum mismatch"):
            load_artifact(self.root, self.descriptor, "Example")

    def test_rejects_missing_artifact(self):
        with self.assertRaisesRegex(ValueError, "exactly one artifact"):
            load_artifact(self.root, self.descriptor, "Missing")

    def test_rejects_invalid_link_shape(self):
        for link in [{"start": 1, "length": 19}, {"start": 3, "length": 20}, {"start": -1, "length": 20}]:
            with self.subTest(link=link):
                self.artifact["bytecode"]["linkReferences"]["src/Math.sol"]["Math"] = [link]
                self.save()
                with self.assertRaisesRegex(ValueError, "invalid library link"):
                    load_artifact(self.root, self.descriptor, "Example")

    def test_rejects_overlapping_links(self):
        self.artifact["bytecode"]["linkReferences"]["src/Math.sol"]["Other"] = [{"start": 1, "length": 20}]
        self.save()
        with self.assertRaisesRegex(ValueError, "overlapping library links"):
            load_artifact(self.root, self.descriptor, "Example")

    def test_rejects_unresolved_bytecode(self):
        self.artifact["bytecode"]["linkReferences"] = {}
        self.save()
        with self.assertRaisesRegex(ValueError, "unresolved creation bytecode"):
            load_artifact(self.root, self.descriptor, "Example")

    def test_rejects_nondeployable_artifact(self):
        self.artifact["bytecode"] = {"object": "0x", "linkReferences": {}}
        self.save()
        with self.assertRaisesRegex(ValueError, "empty creation bytecode"):
            load_artifact(self.root, self.descriptor, "Example")


if __name__ == "__main__":
    unittest.main()
