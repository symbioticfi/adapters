import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import build


class BuildTest(unittest.TestCase):
    def test_builds_every_source_before_the_complete_project(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = []
            for index in range(23):
                path = root / ("src", "script", "test")[index % 3] / f"{index}.sol"
                path.parent.mkdir(exist_ok=True)
                path.touch()
                sources.append(str(path.relative_to(root)))
            (root / "src" / "README.md").touch()
            with patch.object(build, "ROOT", root), patch.object(build.subprocess, "run") as run:
                build.build_project()
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(commands[-1], ["forge", "build"])
            self.assertEqual([path for command in commands[:-1] for path in command[2:]], sorted(sources))
            self.assertTrue(all(0 < len(command[2:]) <= 10 for command in commands[:-1]))

    def test_stops_when_a_compile_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "src" / "Contract.sol").touch()
            with patch.object(build, "ROOT", root), patch.object(
                build.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["forge", "build"])
            ) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    build.build_project()
            self.assertEqual(run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
