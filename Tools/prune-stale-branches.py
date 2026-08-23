#!/usr/bin/env python3
"""Delete branches that no longer have a reason to exist — and refuse to touch anything else.

GitHub's `deleteBranchOnMerge` setting only fires on MERGE. It does nothing for a PR that was
closed without merging, and nothing at all for a branch that never had a PR. Both categories
accumulate silently: an August 2026 sweep of this repository found 80 branches, of which 75 were
dead — three from closed-unmerged PRs and seventy-two working branches from a three-week stretch in
June/July that had never been opened as a PR. None of them were discoverable as garbage without
cross-referencing every branch against every PR by hand.

Nothing here is clever. The value is entirely in the refusals: a branch-deleting robot that gets one
case wrong destroys work, so the keep-rules are checked first, are individually logged, and treat
anything they cannot classify as a keep. Deletion is opt-in per category and every category has an
age floor, because "no open PR" is a statement about the present and a branch pushed an hour ago has
not yet had time to acquire one.

Recovery: every deleted branch is recorded as `<sha> <branch> <reason>` in the manifest written to
--manifest, which the workflow uploads as an artifact. GitHub keeps unreachable objects for a while
after the ref goes, so `git fetch origin <sha>` can still retrieve one from the manifest for a
limited window — do not treat the manifest as a backup. It is a lead, not an archive.

Usage:
    GH_TOKEN=... Tools/prune-stale-branches.py --repo owner/name            # dry run, prints only
    GH_TOKEN=... Tools/prune-stale-branches.py --repo owner/name --execute  # actually deletes
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

API = "https://api.github.com"

# Branches that are never candidates, whatever the PR data says. Release and long-lived integration
# branches do not need a PR to justify themselves, and a glob is easier to audit than a code change.
DEFAULT_KEEP_GLOBS = ("main", "master", "release/*", "gh-pages")


def _request(method: str, path: str, token: str) -> tuple[object, dict[str, str]]:
    req = urllib.request.Request(
        path if path.startswith("http") else f"{API}{path}",
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "noop-prune-stale-branches",
        },
    )
    with urllib.request.urlopen(req) as resp:
        body = resp.read()
        return (json.loads(body) if body else None), dict(resp.headers)


def _paginate(path: str, token: str) -> list[dict]:
    """Follow Link rel=next rather than counting pages — a repo can gain a branch mid-walk."""
    out: list[dict] = []
    url = f"{API}{path}"
    while url:
        page, headers = _request("GET", url, token)
        out.extend(page or [])
        url = ""
        for part in headers.get("Link", "").split(","):
            if 'rel="next"' in part:
                url = part.split(";")[0].strip().strip("<>")
    return out


def _age_days(stamp: str | None, now: datetime) -> float | None:
    if not stamp:
        return None
    return (now - datetime.fromisoformat(stamp.replace("Z", "+00:00"))).total_seconds() / 86400


def classify(branches, pulls, default_branch, keep_globs, now, args, commit_date):
    """Decide each branch's fate. Returns (deletions, keeps) as lists of (branch, sha, reason).

    Written as a pure function over already-fetched data so the rules can be exercised in a test
    without a network or a repository — the whole point of this file is its refusals, and refusals
    that are only observable by deleting something are not testable.
    """
    # A branch protecting an OPEN pull request is untouchable whether it is the head (deleting it
    # closes the PR and loses the review thread's diff) or the BASE (deleting it retargets or breaks
    # every stacked PR built on top of it). The base case is the one that is easy to forget.
    open_heads = {p["head"]["ref"] for p in pulls if p["state"] == "open"}
    open_bases = {p["base"]["ref"] for p in pulls if p["state"] == "open"}

    by_head: dict[str, list[dict]] = {}
    for p in pulls:
        by_head.setdefault(p["head"]["ref"], []).append(p)

    deletions, keeps = [], []
    for br in branches:
        name, sha = br["name"], br["commit"]["sha"]

        def keep(why):
            keeps.append((name, sha, why))

        if name == default_branch:
            keep("default branch")
            continue
        if br.get("protected"):
            keep("branch protection")
            continue
        if any(fnmatch.fnmatch(name, g) for g in keep_globs):
            keep("matches a keep glob")
            continue
        if name in open_heads:
            keep("head of an open PR")
            continue
        if name in open_bases:
            keep("base of an open PR — stacked work depends on it")
            continue

        prs = by_head.get(name, [])
        if not prs:
            # Never had a PR. This is the largest and least certain category: it catches abandoned
            # working branches, but it would also catch a long-running private branch, so it gets
            # much the longest age floor and its own opt-in flag.
            if not args.prune_orphans:
                keep("no PR ever (orphan pruning disabled)")
                continue
            age = _age_days(commit_date(sha), now)
            if age is None:
                keep("no PR ever, and its commit date could not be read")
            elif age < args.orphan_days:
                keep(f"no PR ever, but last commit {age:.0f}d < {args.orphan_days}d")
            else:
                deletions.append((name, sha, f"no PR ever, last commit {age:.0f}d ago"))
            continue

        newest = max(prs, key=lambda p: p["number"])
        if newest.get("merged_at"):
            age = _age_days(newest["merged_at"], now)
            if age is not None and age >= args.merged_days:
                deletions.append((name, sha, f"PR #{newest['number']} merged {age:.0f}d ago"))
            else:
                keep(f"PR #{newest['number']} merged only {age:.0f}d ago")
        elif newest["state"] == "closed":
            age = _age_days(newest["closed_at"], now)
            if age is not None and age >= args.closed_days:
                deletions.append((name, sha, f"PR #{newest['number']} closed unmerged {age:.0f}d ago"))
            else:
                keep(f"PR #{newest['number']} closed only {age:.0f}d ago")
        else:
            # An open PR should have been caught by open_heads above; if the two disagree, the
            # disagreement itself is the reason to do nothing.
            keep(f"PR #{newest['number']} is {newest['state']} — unexpected, refusing")

    return deletions, keeps


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--execute", action="store_true", help="actually delete (default is a dry run)")
    ap.add_argument("--closed-days", type=int, default=14, help="age floor for closed-unmerged PRs")
    ap.add_argument("--merged-days", type=int, default=7, help="age floor for merged PRs")
    ap.add_argument("--orphan-days", type=int, default=90, help="age floor for branches with no PR")
    ap.add_argument("--prune-orphans", action="store_true", help="also delete branches that never had a PR")
    ap.add_argument("--keep", action="append", default=[], help="extra keep glob (repeatable)")
    ap.add_argument("--manifest", help="write '<sha> <branch> <reason>' lines here")
    ap.add_argument("--max-deletes", type=int, default=50,
                    help="refuse to delete more than this in one run; a larger number means "
                         "something is wrong with the rules, not with the repository")
    args = ap.parse_args()

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        print("error: set GH_TOKEN or GITHUB_TOKEN", file=sys.stderr)
        return 2

    now = datetime.now(timezone.utc)
    keep_globs = tuple(DEFAULT_KEEP_GLOBS) + tuple(args.keep)

    repo_info, _ = _request("GET", f"/repos/{args.repo}", token)
    default_branch = repo_info["default_branch"]
    branches = _paginate(f"/repos/{args.repo}/branches?per_page=100", token)
    pulls = _paginate(f"/repos/{args.repo}/pulls?state=all&per_page=100", token)
    print(f"{args.repo}: {len(branches)} branches, {len(pulls)} pull requests, default={default_branch}")

    cache: dict[str, str | None] = {}

    def commit_date(sha: str) -> str | None:
        if sha not in cache:
            try:
                commit, _ = _request("GET", f"/repos/{args.repo}/commits/{sha}", token)
                cache[sha] = commit["commit"]["committer"]["date"]
            except (urllib.error.HTTPError, KeyError, TypeError):
                cache[sha] = None
        return cache[sha]

    deletions, keeps = classify(branches, pulls, default_branch, keep_globs, now, args, commit_date)

    print(f"\nkeeping {len(keeps)}:")
    for name, _, why in sorted(keeps):
        print(f"  {name:<52} {why}")

    print(f"\n{'deleting' if args.execute else 'would delete'} {len(deletions)}:")
    for name, sha, why in sorted(deletions):
        print(f"  {name:<52} {sha[:8]}  {why}")

    if args.manifest and deletions:
        with open(args.manifest, "w", encoding="utf-8") as fh:
            for name, sha, why in sorted(deletions):
                fh.write(f"{sha} {name} {why}\n")
        print(f"\nmanifest: {args.manifest}")

    if not args.execute:
        print("\ndry run — nothing was deleted. Pass --execute to apply.")
        return 0

    # A rule change that suddenly matches everything looks exactly like a correct run until the
    # branches are gone. Stop and make a human look instead.
    if len(deletions) > args.max_deletes:
        print(f"\nerror: {len(deletions)} deletions exceeds --max-deletes={args.max_deletes}; "
              f"refusing. Re-run with a higher limit once the list above has been read.",
              file=sys.stderr)
        return 1

    failed = 0
    for name, sha, _ in sorted(deletions):
        ref = urllib.parse.quote(name, safe="")
        try:
            _request("DELETE", f"/repos/{args.repo}/git/refs/heads/{ref}", token)
            print(f"  deleted {name} ({sha[:8]})")
        except urllib.error.HTTPError as exc:
            failed += 1
            print(f"  FAILED  {name}: {exc.code} {exc.reason}", file=sys.stderr)

    print(f"\ndeleted {len(deletions) - failed}, failed {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
