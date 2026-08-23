#!/usr/bin/env python3
"""Pins what prune-stale-branches.py REFUSES to delete.

A branch-deleting robot is judged entirely by its false positives. Every rule below exists because
getting it wrong destroys work that may have no other copy, and because none of these refusals are
observable in production without deleting something first — so they run here against fabricated API
payloads, with no network and no repository.

Standard `unittest`, discovered by `tools-python.yml` alongside the other Tools/ suites.
"""

from __future__ import annotations

import argparse
import importlib.util
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "prune_stale_branches", Path(__file__).resolve().parent / "prune-stale-branches.py")
prune = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(prune)

NOW = datetime(2026, 8, 23, tzinfo=timezone.utc)


def stamp(days_ago: float) -> str:
    return (NOW - timedelta(days=days_ago)).isoformat().replace("+00:00", "Z")


def branch(name, sha="a" * 40, protected=False):
    return {"name": name, "commit": {"sha": sha}, "protected": protected}


def pr(number, head, state, base="main", merged_at=None, closed_at=None):
    return {"number": number, "state": state, "head": {"ref": head}, "base": {"ref": base},
            "merged_at": merged_at, "closed_at": closed_at}


def classify(branches, pulls, *, prune_orphans=False, orphan_days=90, closed_days=14,
             merged_days=7, commit_ages=None, commit_date=None):
    args = argparse.Namespace(prune_orphans=prune_orphans, orphan_days=orphan_days,
                              closed_days=closed_days, merged_days=merged_days)
    ages = commit_ages or {}
    dater = commit_date if commit_date is not None else (lambda sha: stamp(ages.get(sha, 0)))
    deletions, keeps = prune.classify(
        branches, pulls, "main", prune.DEFAULT_KEEP_GLOBS, NOW, args, dater)
    return {d[0] for d in deletions}, {k[0] for k in keeps}


class Refusals(unittest.TestCase):
    """What the tool must never delete."""

    def test_default_branch_is_never_deleted(self):
        deleted, kept = classify([branch("main")], [])
        self.assertEqual(set(), deleted)
        self.assertIn("main", kept)

    def test_a_protected_branch_is_never_deleted(self):
        """Branch protection is the owner's statement; the tool does not second-guess it."""
        deleted, _ = classify([branch("release-freeze", protected=True)], [])
        self.assertEqual(set(), deleted)

    def test_a_keep_glob_wins_over_having_no_pr(self):
        deleted, _ = classify([branch("release/2.1.0")], [], prune_orphans=True,
                              commit_ages={"a" * 40: 999})
        self.assertEqual(set(), deleted)

    def test_the_head_of_an_open_pr_is_kept(self):
        """Deleting it closes the PR and takes the review thread's diff with it."""
        deleted, _ = classify([branch("feature-x")], [pr(1, "feature-x", "open")])
        self.assertEqual(set(), deleted)

    def test_the_base_of_an_open_pr_is_kept(self):
        """The forgettable case: deleting a base breaks or silently retargets everything stacked
        on it, even when the base's own PR was closed long ago."""
        deleted, _ = classify(
            [branch("stack-base")],
            [pr(1, "stack-base", "closed", closed_at=stamp(200)),
             pr(2, "child", "open", base="stack-base")])
        self.assertEqual(set(), deleted)

    def test_a_recent_branch_with_no_pr_is_kept(self):
        """"No open PR" is a fact about the present. A branch pushed this morning has not yet had
        time to acquire one."""
        deleted, _ = classify([branch("just-pushed")], [], prune_orphans=True,
                              commit_ages={"a" * 40: 3})
        self.assertEqual(set(), deleted)

    def test_orphan_pruning_is_off_by_default(self):
        deleted, _ = classify([branch("abandoned")], [], commit_ages={"a" * 40: 400})
        self.assertEqual(set(), deleted)

    def test_an_unreadable_commit_date_is_kept(self):
        """Unknown age is not old age."""
        deleted, _ = classify([branch("undateable")], [], prune_orphans=True,
                              commit_date=lambda sha: None)
        self.assertEqual(set(), deleted)

    def test_a_recently_closed_pr_keeps_its_branch(self):
        deleted, _ = classify([branch("recent")], [pr(1, "recent", "closed", closed_at=stamp(3))])
        self.assertEqual(set(), deleted)

    def test_a_recently_merged_pr_keeps_its_branch(self):
        deleted, _ = classify([branch("fresh")],
                              [pr(1, "fresh", "closed", merged_at=stamp(2), closed_at=stamp(2))])
        self.assertEqual(set(), deleted)

    def test_a_branch_reused_by_a_newer_open_pr_is_kept(self):
        deleted, _ = classify(
            [branch("reused")],
            [pr(1, "reused", "closed", closed_at=stamp(300)), pr(9, "reused", "open")])
        self.assertEqual(set(), deleted)


class Deletions(unittest.TestCase):
    """What the tool must actually clean up — a prune that refuses everything is also broken."""

    def test_a_long_closed_unmerged_pr_releases_its_branch(self):
        deleted, _ = classify([branch("stale")], [pr(1, "stale", "closed", closed_at=stamp(30))])
        self.assertEqual({"stale"}, deleted)

    def test_a_merged_pr_whose_branch_survived_releases_it(self):
        """deleteBranchOnMerge can fail or postdate the branch; this is the mop-up."""
        deleted, _ = classify([branch("merged")],
                              [pr(1, "merged", "closed", merged_at=stamp(30), closed_at=stamp(30))])
        self.assertEqual({"merged"}, deleted)

    def test_an_opted_in_orphan_past_the_floor_is_deleted(self):
        deleted, _ = classify([branch("ancient")], [], prune_orphans=True,
                              commit_ages={"a" * 40: 400})
        self.assertEqual({"ancient"}, deleted)

    def test_a_mixed_repository_resolves_to_exactly_the_dead_branches(self):
        """The shape of the August 2026 sweep in miniature: the dead go, everything live stays."""
        branches = [branch("main"), branch("feat/live", "b" * 40), branch("dead-closed", "c" * 40),
                    branch("dead-merged", "d" * 40), branch("orphan-old", "e" * 40),
                    branch("orphan-new", "f" * 40)]
        pulls = [pr(10, "feat/live", "open"),
                 pr(11, "dead-closed", "closed", closed_at=stamp(60)),
                 pr(12, "dead-merged", "closed", merged_at=stamp(60), closed_at=stamp(60))]
        deleted, kept = classify(branches, pulls, prune_orphans=True,
                                 commit_ages={"e" * 40: 200, "f" * 40: 5})
        self.assertEqual({"dead-closed", "dead-merged", "orphan-old"}, deleted)
        self.assertEqual({"main", "feat/live", "orphan-new"}, kept)


if __name__ == "__main__":
    unittest.main()
