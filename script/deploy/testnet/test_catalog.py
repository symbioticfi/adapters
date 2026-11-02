import subprocess
import unittest
from pathlib import Path


class CatalogTest(unittest.TestCase):
    def test_repository_catalog_is_complete(self):
        result = subprocess.run(
            ['python3', str(Path(__file__).with_name('check_catalog.py'))],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Covered all 49 wrappers and 3 generic families', result.stdout)
