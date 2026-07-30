#!/usr/bin/env python3
"""Catch doc comments that are silently attached to nothing.

Kotlin and Swift both bind a doc comment to the declaration that FOLLOWS it, and both
take only the LAST one when several are stacked. So a doc block can end up documenting
nothing at all while still reading correctly to a human scrolling past the file — the
text is right there, above the right function, in the right order. That is exactly why
this class of mistake survives review: nothing looks wrong.

It is caused by editing by INSERTION rather than in place — adding a new block above an
existing one, or dropping a new declaration into the gap between a comment and the thing
it documents. Both happened repeatedly in one day (#846 fixed three sites, one of which
had been introduced by #842 that same morning), which is why this exists.

Two patterns, both of which detach the FIRST block:

    /** Byte-parity twin of Swift `classifyCoverage`. */   <- becomes a dangling comment
    /** Both platforms use the NEGATED `>` form ... */     <- this one is the KDoc
    fun classifyCoverage(...)

    /** Persisted preferences file. */

    internal const val PREFS = "..."                       <- blank line detaches the doc

The cost is not cosmetic when the detached text is load-bearing. In #846 the block that
came adrift was a parity-contract statement, and the parity rule is the first thing in
CLAUDE.md — precisely the note you want attached to the function it constrains.

Pre-existing sites are grandfathered in Tools/doc_comment_lint_baseline.txt so the gate
starts green and blocks only NEW ones. It ratchets DOWN: fixing a baselined site prints an
IMPROVED line so the allowance can be lowered.

Usage:  python3 Tools/doc_comment_lint.py
Exit 0 when no file exceeds its allowance, 1 otherwise (with file:line for each).
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

GLOBS = ("android/**/*.kt", "Strand/**/*.swift", "Packages/**/*.swift", "NOOPWatch/**/*.swift")

# A doc block sitting above these is a FILE header, not a declaration doc — the blank line
# after it is conventional and correct, so it must not be reported.
FILE_LEVEL_PREFIXES = ("package ", "import ", "@file:")

# Build output, plus CODE GENERATOR output. `/Generated/` is the same kind of exclusion as the three
# build directories, not a baseline raise: this lint exists to catch a HAND-EDITING failure mode —
# "editing by INSERTION rather than in place" — and a generator never edits, it re-emits. The one
# directory this currently matches, Strand/CloudSync/Generated/, is `rm -rf`'d and rewritten by
# `Rust/build-ios.sh` on every build; its header reads "Do not edit by hand" and it already carries
# `// swiftlint:disable all`, so a fix applied there is deleted by the next regeneration and the
# finding returns. Two of uniffi's emissions defeat a fix outright: it puts a blank line between a
# `/** */` block and the `public enum` it documents (4 sites), and it inlines a parameter's doc INSIDE
# the argument list (`public init(/** … */restored: Bool, …)`), which this file's scanner mis-walks —
# that block is correctly bound to its parameter, so there is nothing there to repair.
SKIP_PARTS = ("/build/", "/.build/", "/DerivedData/", "/Generated/")


def _is_doc_open(line: str) -> bool:
    """A doc-comment opener: `/**`, but not the empty block `/**/`."""
    s = line.strip()
    return s.startswith("/**") and s != "/**/"


def findings(path: Path) -> list[tuple[int, str]]:
    """(1-indexed line, reason) for every detached doc block in one file."""
    lines = path.read_text(errors="ignore").splitlines()
    out: list[tuple[int, str]] = []
    i = 0
    while i < len(lines):
        if not _is_doc_open(lines[i]):
            i += 1
            continue
        start = i
        # Walk to the block's close. A single-line `/** … */` closes on its own line.
        end = start
        if not lines[start].strip().endswith("*/") or lines[start].strip() == "/**":
            end += 1
            while end < len(lines) and not lines[end].strip().endswith("*/"):
                end += 1
            if end >= len(lines):
                break  # unterminated block — a compile error, not this tool's business

        nxt = end + 1
        if nxt < len(lines):
            after = lines[nxt].strip()
            if _is_doc_open(lines[nxt]):
                out.append((start + 1, "stacked: the block below it wins, this one documents nothing"))
            elif after == "":
                # Blank line, then a real declaration ⇒ detached. A file header is exempt.
                follow = nxt + 1
                while follow < len(lines) and lines[follow].strip() == "":
                    follow += 1
                if follow < len(lines):
                    code = lines[follow].strip()
                    is_header = code.startswith(FILE_LEVEL_PREFIXES)
                    is_comment = code.startswith(("//", "/*", "*"))
                    if code and not is_header and not is_comment:
                        out.append((start + 1, "blank line before the declaration detaches it"))
        i = end + 1
    return out


BASELINE = ROOT / "Tools/doc_comment_lint_baseline.txt"


def read_baseline() -> dict[str, int]:
    """`path -> allowed count` of pre-existing sites.

    Counts, not line numbers: line numbers churn on every edit above them, so a
    line-keyed baseline would go stale constantly and train people to regenerate it
    without looking. A count only moves when someone adds or removes a site, which is
    exactly the event worth gating on. It ratchets DOWN — fixing sites below the
    allowance is reported so the entry can be lowered.
    """
    if not BASELINE.exists():
        return {}
    out: dict[str, int] = {}
    for raw in BASELINE.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        path, _, count = line.rpartition(" ")
        out[path.strip()] = int(count)
    return out


def main() -> int:
    baseline = read_baseline()
    by_file: dict[str, list[str]] = {}
    scanned = 0
    for glob in GLOBS:
        for path in sorted(ROOT.glob(glob)):
            if any(p in str(path) for p in SKIP_PARTS):
                continue
            scanned += 1
            found = findings(path)
            if found:
                rel = str(path.relative_to(ROOT))
                by_file[rel] = [f"{rel}:{ln}  {why}" for ln, why in found]

    regressions = [h for f, hs in sorted(by_file.items())
                   for h in hs if len(hs) > baseline.get(f, 0)]
    improved = [(f, baseline[f], len(by_file.get(f, [])))
                for f in sorted(baseline) if len(by_file.get(f, [])) < baseline[f]]

    for f, was, now in improved:
        print(f"IMPROVED {f}: {was} -> {now}. Lower it in {BASELINE.name}"
              + (" (or drop the line)." if now == 0 else "."))

    if regressions:
        print(f"\nFAIL {len(regressions)} detached doc comment(s) beyond the baseline:\n")
        for h in regressions:
            print(f"  {h}")
        print(
            "\nBoth patterns leave the text readable but bound to nothing — Dokka and IDE\n"
            "hover will not show it. Merge the blocks, or move the inserted declaration\n"
            "above the doc. Do NOT raise the baseline to make this pass."
        )
        return 1

    total = sum(len(v) for v in by_file.values())
    print(f"OK no NEW detached doc comments ({scanned} files, {total} baselined site(s) remaining)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
