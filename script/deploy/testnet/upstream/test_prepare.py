import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from prepare import attest_build


class PrepareTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for args in [("init", "-q"), ("config", "user.email", "test@example.com"), ("config", "user.name", "Test")]:
            subprocess.run(["git", "-C", str(self.root), *args], check=True)
        (self.root / "source.sol").write_text("contract Source {}")
        subprocess.run(["git", "-C", str(self.root), "add", "source.sol"], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"], check=True)
        commit = subprocess.check_output(["git", "-C", str(self.root), "rev-parse", "HEAD"], text=True).strip()
        self.pin = {"repository": "https://github.com/example/protocol", "commit": commit, "submodules": {}}
        self.artifact = self.root / "out" / "Source.sol" / "Source.json"
        self.artifact.parent.mkdir(parents=True)
        self.artifact.write_text('{"bytecode":{"object":"0x6000"}}')

    def test_attests_artifact_and_source_pin(self):
        attest_build(self.root, self.pin)
        stamp = json.loads((self.root / ".merkle-artifacts.json").read_text())
        self.assertEqual(stamp["descriptor"], self.pin)
        self.assertIn("out/Source.sol/Source.json", stamp["artifacts"])

    def test_refuses_different_source_commit(self):
        with self.assertRaisesRegex(ValueError, "source commit does not match"):
            attest_build(self.root, {**self.pin, "commit": "a" * 40})

    def test_refuses_modified_upstream_source(self):
        (self.root / "source.sol").write_text("contract Different {}")
        with self.assertRaisesRegex(ValueError, "modified upstream source"):
            attest_build(self.root, self.pin)

    def test_refuses_dependency_mismatch(self):
        with self.assertRaisesRegex(ValueError, "dependency pins do not match"):
            attest_build(self.root, {**self.pin, "submodules": {"lib/missing": "a" * 40}})

    def test_refuses_missing_creation_artifacts(self):
        self.artifact.unlink()
        with self.assertRaisesRegex(ValueError, "no creation artifacts"):
            attest_build(self.root, self.pin)


if __name__ == "__main__":
    unittest.main()
