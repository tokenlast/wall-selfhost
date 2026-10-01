import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from approve_device import approve


class SelfHostTests(unittest.TestCase):
    def test_approval_only_changes_the_selected_pending_device(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = {"hash": "a" * 64, "label": "Fixture tablet A"}
            second = {"hash": "b" * 64, "label": "Fixture tablet B"}
            (root / "pending-devices.json").write_text(json.dumps([first, second]))
            approve(root, first["hash"])
            self.assertEqual(json.loads((root / "approved-devices.json").read_text()), [first])
            self.assertEqual(json.loads((root / "pending-devices.json").read_text()), [second])
            self.assertEqual((root / "approved-devices.json").stat().st_mode & 0o777, 0o600)
            with self.assertRaises(ValueError):
                approve(root, "c" * 64)
            self.assertEqual(json.loads((root / "approved-devices.json").read_text()), [first])

    def test_blank_example_authentication_prevents_server_startup(self):
        source = Path(__file__).resolve().parents[1]
        env = dict(os.environ)
        for line in (source / "config.env.example").read_text().splitlines():
            if line and not line.startswith("#"):
                key, value = line.split("=", 1)
                env[key] = value
        with tempfile.TemporaryDirectory() as directory:
            env["WALL_DATA_DIR"] = directory
            result = subprocess.run([sys.executable, str(source / "server.py")], env=env,
                                    capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("WALL_PASSWORD_HASH", result.stderr)


if __name__ == "__main__":
    unittest.main()
