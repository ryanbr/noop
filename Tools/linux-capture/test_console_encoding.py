"""Executable-path coverage for consoles that default to a legacy Windows encoding.

The subprocesses run on Linux with strict cp1252 stdout/stderr. This reproduces the encoding
constraint but is not a native Windows test.
"""

import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent


def _run_cp1252(script, *args):
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "cp1252:strict"
    return subprocess.run(
        [sys.executable, str(HERE / script), *map(str, args)],
        cwd=HERE,
        env=env,
        capture_output=True,
        timeout=10,
    )


class ConsoleEncodingTests(unittest.TestCase):
    def test_analyze_v25_real_entrypoint_is_unicode_safe(self):
        result = _run_cp1252("analyze_v25_waveform.py")
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        self.assertIn("running the DEMO", result.stdout.decode("utf-8"))

    def test_whoop_sync_real_entrypoint_is_unicode_safe(self):
        with tempfile.TemporaryDirectory() as td:
            db_path = os.path.join(td, "capture.db")
            con = sqlite3.connect(db_path)
            con.execute(
                "CREATE TABLE devices (id INTEGER PRIMARY KEY, address TEXT NOT NULL UNIQUE, "
                "name TEXT, subject TEXT, model TEXT, created_ms INTEGER)"
            )
            con.execute(
                "CREATE TABLE frames (id INTEGER PRIMARY KEY, device_id INTEGER NOT NULL, "
                "recv_ms INTEGER NOT NULL, char TEXT, inner_type INTEGER, unix INTEGER, "
                "hr INTEGER, hex TEXT NOT NULL, UNIQUE(device_id, hex))"
            )
            con.execute(
                "INSERT INTO devices(address, name, model) VALUES('AA:BB:CC:DD:EE:FF', 'strap', 'whoop4')"
            )
            con.commit()
            con.close()

            result = _run_cp1252("whoop_sync.py", "devices", "--db", db_path)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        self.assertIn("→", result.stdout.decode("utf-8"))


if __name__ == "__main__":
    unittest.main()
