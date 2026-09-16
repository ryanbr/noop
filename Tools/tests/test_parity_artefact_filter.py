"""The scan must see the repository's source, not the working tree's build output."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS = Path(__file__).resolve().parents[1]
REPOSITORY = TOOLS.parent
sys.path.insert(0, str(TOOLS))

import parity_ledger  # noqa: E402


ALL_GLOB_SETS = (
    parity_ledger.SWIFT_GLOBS,
    parity_ledger.KOTLIN_GLOBS,
    parity_ledger.PRODUCTION_GLOBS,
    parity_ledger.TEST_GLOBS,
    parity_ledger.REFERENCE_GLOBS,
)


class BuildArtefactFilterTests(unittest.TestCase):
    """Why this exists: `**` descends into `.build/checkouts` exactly as into a source tree, and a
    SwiftPM dependency that lays itself out with a `Sources` directory then matches
    `Packages/**/Sources/**/*.swift`. The damage is SUBTRACTIVE: a vendored copy of somebody else's
    library hands a declaration a callsite it does not really have, so a finding DISAPPEARS. CI checks
    out clean and never sees it, and the local acceptance test compares two artefacts derived from the
    same polluted tree, so it passes. That combination is what makes it worth a test of its own."""

    def test_nothing_the_repository_tracks_is_ever_dropped(self):
        """The safety invariant, checked against git rather than asserted: build output is untracked,
        source is tracked, so the filter can never hide a file the repository actually contains."""
        tracked = set(subprocess.run(
            ["git", "ls-files", "-z"], cwd=REPOSITORY,
            capture_output=True, text=True, check=True).stdout.split("\0"))
        dropped = set()
        for globs in ALL_GLOB_SETS:
            for pattern in globs:
                for path in REPOSITORY.glob(pattern):
                    if path.is_file() and parity_ledger._is_build_artefact(REPOSITORY, path):
                        dropped.add(path.relative_to(REPOSITORY).as_posix())
        self.assertEqual(sorted(dropped & tracked), [],
                         "the artefact filter dropped a git-tracked file")

    def test_a_dependency_checkout_under_sources_is_not_scanned(self):
        """The exact shape that caused it: a checkout whose own layout puts a `Sources` directory
        under `.build`, which the production glob then matches."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            real = root / "Packages" / "Thing" / "Sources" / "Thing"
            real.mkdir(parents=True)
            (real / "Real.swift").write_text("// first-party\n", encoding="utf-8")
            vendored = root / "Packages" / "Thing" / ".build" / "checkouts" / "Dep" / "Sources" / "Dep"
            vendored.mkdir(parents=True)
            (vendored / "Vendored.swift").write_text("// somebody else's\n", encoding="utf-8")

            found = parity_ledger._paths(root, ("Packages/**/Sources/**/*.swift",))
            names = [p.name for p in found]
            self.assertIn("Real.swift", names)
            self.assertNotIn("Vendored.swift", names)

    def test_index_build_is_dropped_too(self):
        """SwiftPM writes a second copy under `.build/index-build`; both were being scanned."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            p = root / "Packages" / "T" / ".build" / "index-build" / "checkouts" / "D" / "Sources" / "D"
            p.mkdir(parents=True)
            (p / "Indexed.swift").write_text("//\n", encoding="utf-8")
            self.assertEqual(parity_ledger._paths(root, ("Packages/**/Sources/**/*.swift",)), [])

    def test_gradle_output_is_dropped_before_it_can_matter(self):
        """No Kotlin lands under `android/**/build` today, because KSP emits Java. That is a property
        of the current toolchain rather than a guarantee, and the reference glob is `android/**/*.kt`."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            gen = root / "android" / "app" / "build" / "generated" / "ksp" / "main" / "kotlin"
            gen.mkdir(parents=True)
            (gen / "Generated.kt").write_text("// generated\n", encoding="utf-8")
            src = root / "android" / "app" / "src" / "main" / "java" / "com" / "noop"
            src.mkdir(parents=True)
            (src / "Hand.kt").write_text("// hand-written\n", encoding="utf-8")

            found = [p.name for p in parity_ledger._paths(root, ("android/**/*.kt",))]
            self.assertEqual(found, ["Hand.kt"])

    def test_a_source_file_is_not_dropped_for_a_lookalike_name(self):
        """`build` is excluded as a directory component only. A file called `build.swift`, or a
        directory whose name merely contains it, stays in the scan."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            d = root / "Packages" / "T" / "Sources" / "buildsystem"
            d.mkdir(parents=True)
            (d / "build.swift").write_text("//\n", encoding="utf-8")
            found = [p.name for p in parity_ledger._paths(root, ("Packages/**/Sources/**/*.swift",))]
            self.assertEqual(found, ["build.swift"])
