"""Tests for protocol-document source reference validation."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER_PATH = REPO_ROOT / "docs/protocol-examples/check_source_references.py"
SPEC = importlib.util.spec_from_file_location("check_source_references", CHECKER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load source-reference checker from {CHECKER_PATH}")
check_source_references = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_source_references)


class SourceReferenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        # Resolved because the checker resolves every path it is given, and on macOS the
        # temp directory sits under /var, a symlink to /private/var.
        self.root = Path(self.temp.name).resolve()
        self.docs = self.root / "docs"
        self.sources = self.root / "Sources"
        self.docs.mkdir()
        self.sources.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write(self, relative: str, text: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def run_doc(self, doc: Path) -> tuple[int, list[str]]:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = check_source_references.main([str(doc)])
        return code, output.getvalue().splitlines()

    def test_valid_symbol_description_and_backtick_references(self) -> None:
        self.write("Sources/Client.swift", "func decode(value: Int) {}\n")
        self.write("Sources/support.py", "HELP_TEXT = 'protocol support'\n")
        self.write("Sources/config.json", "{}\n")
        doc = self.write(
            "docs/PROTOCOL.md",
            """[Client.decode(value:)](../Sources/Client.swift)
[implementation source](../Sources/support.py)
`../Sources/config.json`
""",
        )

        code, lines = self.run_doc(doc)

        self.assertEqual(0, code)
        self.assertEqual(["checked 3 references, 3 files, 0 failures"], lines)

    def test_missing_symbol_reports_line_and_failure(self) -> None:
        self.write("Sources/Client.swift", "func available() {}\n")
        doc = self.write(
            "docs/PROTOCOL.md",
            "Intro\n[Client.missing()](../Sources/Client.swift)\n",
        )

        code, lines = self.run_doc(doc)

        self.assertEqual(1, code)
        self.assertEqual(2, len(lines))
        self.assertEqual(
            f"FAIL {doc}:2 ../Sources/Client.swift [missing] symbol not found",
            lines[0],
        )
        self.assertEqual("checked 1 references, 1 files, 1 failures", lines[1])

    def test_missing_link_target_reports_file_failure(self) -> None:
        doc = self.write(
            "docs/PROTOCOL.md",
            "[missing implementation](../Sources/Missing.swift)\n",
        )

        code, lines = self.run_doc(doc)

        self.assertEqual(1, code)
        self.assertEqual(
            f"FAIL {doc}:1 ../Sources/Missing.swift file does not exist",
            lines[0],
        )
        self.assertEqual("checked 1 references, 1 files, 1 failures", lines[1])

    def test_missing_backtick_target_reports_file_failure(self) -> None:
        doc = self.write("docs/PROTOCOL.md", "Use `../Sources/missing.py` for details.\n")

        code, lines = self.run_doc(doc)

        self.assertEqual(1, code)
        self.assertEqual(
            f"FAIL {doc}:1 ../Sources/missing.py file does not exist",
            lines[0],
        )
        self.assertEqual("checked 1 references, 1 files, 1 failures", lines[1])

    def test_qualified_signature_extracts_final_symbol_and_matches_whole_words(self) -> None:
        self.assertEqual(
            "method",
            check_source_references.symbol_from_text("A.B.method(x:y:)"),
        )
        self.write("Sources/Client.swift", "func decodeAll() {}\n")
        doc = self.write(
            "docs/PROTOCOL.md",
            "[A.B.decode(x:y:)](../Sources/Client.swift)\n",
        )

        code, lines = self.run_doc(doc)

        self.assertEqual(1, code)
        self.assertEqual(
            f"FAIL {doc}:1 ../Sources/Client.swift [decode] symbol not found",
            lines[0],
        )
        self.assertEqual("checked 1 references, 1 files, 1 failures", lines[1])

    def test_repository_protocol_document_passes_smoke_check(self) -> None:
        result = subprocess.run(
            [sys.executable, str(CHECKER_PATH), str(REPO_ROOT / "docs/PROTOCOL_IMPLEMENTATION.md")],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("0 failures", result.stdout.splitlines()[-1])


if __name__ == "__main__":
    unittest.main()
