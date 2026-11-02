import contextlib
import io
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import generate_snapshots as snapshots


class GenerateSnapshotsTest(unittest.TestCase):
    def test_sorts_complete_tables_without_console_noise(self):
        output = "log\n╭ Z ╮\nz\n╰───╯\nnoise\n╭ A ╮\na\n╰───╯\n"
        self.assertEqual(snapshots.report_tables(output), "╭ A ╮\na\n╰───╯\n\n╭ Z ╮\nz\n╰───╯\n")

    def test_rejects_missing_or_incomplete_tables(self):
        for output in ["no report", "╭ report\nincomplete"]:
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "did not contain any report tables"):
                snapshots.report_tables(output)

    def test_propagates_forge_failure_and_diagnostics(self):
        result = subprocess.CompletedProcess([], 7, "failed test\n", "forge error\n")
        error = io.StringIO()
        with patch.object(snapshots.subprocess, "run", return_value=result), contextlib.redirect_stderr(error):
            with self.assertRaises(SystemExit) as raised:
                snapshots.run_forge("test")
        self.assertEqual(raised.exception.code, 7)
        self.assertEqual(error.getvalue(), "failed test\nforge error\n")

    def test_preserves_both_reports_when_any_forge_check_fails(self):
        table = "╭ report\n╰───╯\n"
        for failed_check in range(4):
            with self.subTest(failed_check=failed_check), tempfile.TemporaryDirectory() as directory:
                reports = Path(directory)
                for name in ["sizes.txt", "gas.txt"]:
                    (reports / name).write_text("existing report\n")
                results = [table] * 3
                if failed_check:
                    results[failed_check - 1] = SystemExit(7)
                with patch.object(snapshots, "SNAPSHOTS_DIR", reports), patch.object(
                    snapshots, "build_project", side_effect=SystemExit(7) if failed_check == 0 else None
                ), patch.object(
                    snapshots, "run_forge", side_effect=results
                ), self.assertRaises(SystemExit):
                    snapshots.main()
                for name in ["sizes.txt", "gas.txt"]:
                    self.assertEqual((reports / name).read_text(), "existing report\n")

    def test_writes_both_reports_after_successful_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            reports = Path(directory) / "snapshots"
            with patch.object(snapshots, "SNAPSHOTS_DIR", reports), patch.object(
                snapshots, "build_project"
            ), patch.object(
                snapshots, "run_forge", side_effect=["╭ sizes\n╰───╯\n", "╭ gas\n╰───╯\n", ""]
            ):
                snapshots.main()
            self.assertEqual((reports / "sizes.txt").read_text(), "╭ sizes\n╰───╯\n")
            self.assertEqual((reports / "gas.txt").read_text(), "╭ gas\n╰───╯\n")


if __name__ == "__main__":
    unittest.main()
