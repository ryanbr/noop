#!/usr/bin/env python3
"""Fail-closed governance ratchet for the checked-in parity inventory.

This first layer deliberately governs metadata only.  It prevents the lexical
inventory or its accepted debt from being weakened in the same change that
updates the baseline.  Differential runners, corpora, execution coverage and
native orchestration are separate layers and are not dependencies of this
tool.
"""

from __future__ import annotations

import argparse
import io
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from contextlib import contextmanager
from datetime import date, datetime
from pathlib import Path
from typing import Iterable

import issue_ref
import parity_ledger


ROOT = Path(__file__).resolve().parent.parent
TWIN_MAP_PATH = "Tools/parity_twin_map.json"
LEDGER_BASELINE_PATH = "Tools/parity_ledger_baseline.json"
DISPOSITIONS_PATH = "Tools/parity_dispositions.json"
class RatchetError(ValueError):
    """Raised when governance inputs cannot be interpreted safely."""


def _git(root: Path, arguments: list[str]) -> str:
    try:
        return subprocess.check_output(
            ["git", *arguments], cwd=root, text=True, stderr=subprocess.STDOUT
        ).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = exc.output.strip() if isinstance(exc, subprocess.CalledProcessError) and exc.output else str(exc)
        raise RatchetError(f"git {' '.join(arguments)} failed: {detail}") from exc


def resolve_base(root: Path, base: str | None) -> str:
    """Resolve the exact requested base, defaulting to current ``origin/main``."""
    return _git(root, ["rev-parse", "--verify", base or "origin/main"])


def _read_current(root: Path, relative: str) -> dict:
    path = root / relative
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        issue_ref.validate_current_issue_fields(value, relative)
    except (OSError, json.JSONDecodeError, issue_ref.IssueRefError) as exc:
        raise RatchetError(f"cannot read current {relative}: {exc}") from exc
    if not isinstance(value, dict):
        raise RatchetError(f"{relative}: JSON root must be an object")
    return value


def _read_current_dispositions(root: Path) -> dict:
    path = root / DISPOSITIONS_PATH
    if not path.exists():
        return {"schema_version": 1, "dispositions": []}
    return _read_current(root, DISPOSITIONS_PATH)


def _read_base(root: Path, base: str, relative: str) -> dict | None:
    try:
        raw = subprocess.check_output(
            ["git", "show", f"{base}:{relative}"],
            cwd=root,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        try:
            listed = subprocess.check_output(
                ["git", "ls-tree", "--name-only", base, "--", relative],
                cwd=root,
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except (OSError, subprocess.CalledProcessError) as tree_exc:
            raise RatchetError(
                f"cannot inspect base {base}:{relative}: {tree_exc}"
            ) from tree_exc
        if not listed:
            return None
        detail = exc.output.strip() if isinstance(exc, subprocess.CalledProcessError) and exc.output else str(exc)
        raise RatchetError(f"cannot read base {base}:{relative}: {detail}") from exc
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RatchetError(f"{base}:{relative}: invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise RatchetError(f"{base}:{relative}: JSON root must be an object")
    issue_ref.validate_current_issue_fields(value, f"{base}:{relative}")
    return value


def _array(value: dict, key: str, location: str) -> list:
    result = value.get(key)
    if not isinstance(result, list):
        raise RatchetError(f"{location}: {key} must be an array")
    return result


def _validate_twin_map(value: dict, location: str) -> None:
    if value.get("schema_version") != 3:
        raise RatchetError(f"{location}: schema_version must be 3")
    expected_keys = {"schema_version", "derivation", "scope", "authority"}
    if set(value) != expected_keys:
        raise RatchetError(f"{location}: v3 top-level keys must be exact")
    if value.get("derivation") != "parity_ledger.build_twin_map/v3":
        raise RatchetError(f"{location}: unsupported v3 derivation")
    expected_scope = {
        "swift_roots": [glob.split("/**", 1)[0] for glob in parity_ledger.SWIFT_GLOBS],
        "kotlin_roots": [glob.split("/**", 1)[0] for glob in parity_ledger.KOTLIN_GLOBS],
    }
    if value.get("scope") != expected_scope:
        raise RatchetError(f"{location}: scope must equal the exact derivation roots")
    authority = value.get("authority")
    required = set(parity_ledger.SEMANTIC_AUTHORITY_SETS)
    if not isinstance(authority, dict) or set(authority) != required:
        raise RatchetError(f"{location}: authority must contain every semantic set exactly")
    for name, item in authority.items():
        if (not isinstance(item, dict) or set(item) != {"count", "sha256"}
                or type(item.get("count")) is not int or item["count"] < 0
                or not isinstance(item.get("sha256"), str)
                or re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) is None):
            raise RatchetError(f"{location}: authority.{name} needs count and lowercase SHA-256")


def _validate_dispositions(value: dict, location: str) -> None:
    if value.get("schema_version") != 1 or set(value) != {"schema_version", "dispositions"}:
        raise RatchetError(f"{location}: typed disposition registry keys must be exact")
    dispositions = value.get("dispositions")
    if not isinstance(dispositions, list):
        raise RatchetError(f"{location}: dispositions must be an array")
    seen_identities: set[str] = set()
    seen_issues: set[issue_ref.IssueRef] = set()
    forbidden = issue_ref.parse_current("bhelm/noop#17")
    allowed_kinds = {
        "add-unpaired-file", "add-unpaired-function", "add-unpaired-property",
        "add-unpaired-constant",
    }
    for index, item in enumerate(dispositions):
        prefix = f"{location}: dispositions[{index}]"
        if not isinstance(item, dict):
            raise RatchetError(f"{prefix} must be an object")
        disposition_type = item.get("type")
        common = {"type", "kind", "identity", "identity_sha256", "platform"}
        expected = {
            "experimental": common | {"issue", "reason", "expires_on"},
            "platform_specific": common | {"rationale"},
        }.get(disposition_type)
        if expected is None or set(item) != expected:
            missing = "expires_on" if disposition_type == "experimental" and "expires_on" not in item else "keys"
            raise RatchetError(f"{prefix} {missing} must be exact for type {disposition_type!r}")
        kind, identity = item["kind"], item["identity"]
        reason = item["reason"] if disposition_type == "experimental" else item["rationale"]
        if (not isinstance(kind, str) or not kind or not isinstance(identity, str)
                or not identity or "*" in identity):
            raise RatchetError(f"{prefix} needs exact kind and identity without globs")
        if kind not in allowed_kinds:
            raise RatchetError(f"{prefix} cannot waive shared parity or pair removal: {kind!r}")
        platform = item.get("platform")
        if platform not in {"swift", "kotlin"} or not identity.startswith(platform + "\0"):
            raise RatchetError(f"{prefix} platform must match the exact identity")
        if item["identity_sha256"] != parity_ledger._canonical_sha256(identity):
            raise RatchetError(f"{prefix} identity hash mismatch")
        if not isinstance(reason, str) or len(reason.strip()) < 20:
            raise RatchetError(f"{prefix} needs a specific non-generic rationale")
        issue = issue_ref.parse_current(item["issue"]) if disposition_type == "experimental" else None
        if issue == forbidden:
            raise RatchetError(f"{prefix}: umbrella issue bhelm/noop#17 is forbidden")
        if disposition_type == "experimental":
            try:
                datetime.strptime(item["expires_on"], "%Y-%m-%d")
            except (TypeError, ValueError) as exc:
                raise RatchetError(f"{prefix} expires_on must be YYYY-MM-DD") from exc
        if identity in seen_identities or (issue is not None and issue in seen_issues):
            raise RatchetError(f"{location}: dispositions require unique exact identities and issues")
        seen_identities.add(identity)
        if issue is not None:
            seen_issues.add(issue)


def _validate_baseline(value: dict, location: str) -> None:
    if value.get("schema_version") != 3 or set(value) != {"schema_version", "accepted_findings", "counters"}:
        raise RatchetError(f"{location}: compact baseline v3 keys must be exact")
    groups = _array(value, "accepted_findings", location)
    identities: set[tuple[str, str]] = set()
    group_keys = {"rule", "scope", "reason", "provenance", "count", "identities_sha256"}
    for index, group in enumerate(groups):
        if not isinstance(group, dict) or set(group) != group_keys:
            raise RatchetError(f"{location}: accepted_findings[{index}] keys must be exact")
        for key in ("rule", "scope", "reason", "provenance"):
            if not isinstance(group[key], str) or not group[key].strip():
                raise RatchetError(f"{location}: accepted_findings[{index}] needs non-empty {key}")
        expected_reason = parity_ledger.BASELINE_REASONS.get(group["rule"])
        expected_provenance = parity_ledger.baseline_group_provenance(
            group["rule"], group["scope"]
        )
        if group["reason"] != expected_reason or group["provenance"] != expected_provenance:
            raise RatchetError(
                f"{location}: accepted_findings[{index}] must retain its canonical reviewed reason and provenance"
            )
        identity = (group["rule"], group["scope"])
        if identity in identities:
            raise RatchetError(f"{location}: duplicate accepted finding group {identity}")
        identities.add(identity)
        if (type(group["count"]) is not int or group["count"] < 1
                or not isinstance(group["identities_sha256"], str)
                or re.fullmatch(r"[0-9a-f]{64}", group["identities_sha256"]) is None):
            raise RatchetError(f"{location}: accepted_findings[{index}] needs count and identity SHA-256")
    counters = value.get("counters")
    if not isinstance(counters, dict):
        raise RatchetError(f"{location}: counters must be an object")
    for name, count in counters.items():
        if not isinstance(name, str) or type(count) is not int or count < 0:
            raise RatchetError(f"{location}: counter {name!r} must be a non-negative integer")


def _issues(value: object) -> set[issue_ref.IssueRef]:
    found: set[issue_ref.IssueRef] = set()

    def walk(node: object) -> None:
        if isinstance(node, dict):
            for key, child in node.items():
                if key == "issue":
                    found.add(issue_ref.parse_current(child))
                walk(child)
        elif isinstance(node, list):
            for child in node:
                walk(child)

    walk(value)
    return found


def _fetch_issue(issue: issue_ref.IssueRef) -> dict | None:
    try:
        response = subprocess.run(
            ["gh", "api", f"repos/{issue.repo}/issues/{issue.number}"],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise RatchetError("gh is required for online issue validation") from exc
    except (OSError, subprocess.CalledProcessError):
        return None
    try:
        payload = json.loads(response.stdout)
    except (TypeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _issue_payload_matches(issue: issue_ref.IssueRef, payload: dict | None) -> bool:
    """Validate both issue number and repository; pull requests do not qualify."""
    if payload is None or "pull_request" in payload:
        return False
    if type(payload.get("number")) is not int or payload["number"] != issue.number:
        return False
    proofs: list[bool] = []
    if "repository_url" in payload:
        proofs.append(payload["repository_url"] == f"https://api.github.com/repos/{issue.repo}")
    if "html_url" in payload:
        proofs.append(payload["html_url"] == f"https://github.com/{issue.repo}/issues/{issue.number}")
    return bool(proofs) and all(proofs)


def issue_exists(issue: issue_ref.IssueRef) -> bool:
    return _issue_payload_matches(issue, _fetch_issue(issue))


def _exemption_payload_is_bound(
    issue: issue_ref.IssueRef,
    payload: dict | None,
    identity_sha256: str,
    base_created_at: str,
) -> bool:
    try:
        created = datetime.fromisoformat(str(payload["created_at"]).replace("Z", "+00:00"))
        base_created = datetime.fromisoformat(base_created_at.replace("Z", "+00:00"))
    except (TypeError, KeyError, ValueError):
        return False
    return (
        _exemption_payload_has_identity(issue, payload, identity_sha256)
        and payload.get("state") == "open"
        and created > base_created
    )


def _exemption_payload_has_identity(
    issue: issue_ref.IssueRef, payload: dict | None, identity_sha256: str
) -> bool:
    marker = f"parity-governance-identity-sha256: {identity_sha256}"
    return (
        _issue_payload_matches(issue, payload)
        and isinstance(payload.get("body"), str)
        and marker in payload["body"]
    )


def exemption_issue_is_bound(
    issue: issue_ref.IssueRef, identity_sha256: str, base_created_at: str
) -> bool:
    """Require a post-base issue whose body names the exact governed identity hash."""
    return _exemption_payload_is_bound(
        issue, _fetch_issue(issue), identity_sha256, base_created_at
    )


@contextmanager
def _base_tree(root: Path, base: str):
    """Materialize the exact base tree; unavailable/shallow bases fail closed."""
    try:
        archive = subprocess.check_output(
            ["git", "archive", "--format=tar", base], cwd=root, stderr=subprocess.STDOUT
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = exc.output.decode(errors="replace").strip() if isinstance(exc, subprocess.CalledProcessError) else str(exc)
        raise RatchetError(f"cannot independently scan base {base}: {detail}") from exc
    with tempfile.TemporaryDirectory() as directory:
        target = Path(directory)
        try:
            with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as bundle:
                bundle.extractall(target, filter="data")
        except (tarfile.TarError, TypeError) as exc:
            raise RatchetError(f"cannot materialize base {base}: {exc}") from exc
        yield target


def _required_v3_exemptions(
    base_sets: dict[str, list[str]],
    current_sets: dict[str, list[str]],
    base_findings: set[str],
    current_findings: set[str],
) -> set[tuple[str, str]]:
    required: set[tuple[str, str]] = set()
    for name in (
        "unpaired_files",
        "unpaired_functions",
        "unpaired_properties",
        "unpaired_constants",
    ):
        for identity in set(current_sets[name]) - set(base_sets[name]):
            required.add((f"add-{name[:-1].replace('_', '-')}", identity))
    for name in ("function_pairs", "property_pairs", "constant_pairs"):
        for identity in set(base_sets[name]) - set(current_sets[name]):
            required.add((f"remove-{name[:-1].replace('_', '-')}", identity))
    for identity in current_findings - base_findings:
        required.add(("add-finding", identity))
    return required


def _exemption_applies(
    key: tuple[str, str],
    current_sets: dict[str, list[str]],
    current_findings: set[str],
    current_counters: dict[str, int],
    bootstrap_unpaired_debts: set[str],
) -> bool:
    kind, identity = key
    add_sets = {
        "add-unpaired-file": "unpaired_files",
        "add-unpaired-function": "unpaired_functions",
        "add-unpaired-property": "unpaired_properties",
        "add-unpaired-constant": "unpaired_constants",
    }
    remove_sets = {
        "remove-function-pair": "function_pairs",
        "remove-property-pair": "property_pairs",
        "remove-constant-pair": "constant_pairs",
    }
    if kind in add_sets:
        return identity in current_sets[add_sets[kind]]
    if kind in remove_sets:
        return identity not in current_sets[remove_sets[kind]]
    if kind == "add-finding":
        return identity in current_findings
    if kind == "bootstrap-unpaired-function":
        return identity in current_sets["unpaired_functions"] and identity in bootstrap_unpaired_debts
    if kind == "add-counter":
        parts = identity.split("\u0000")
        try:
            return len(parts) == 3 and current_counters.get(parts[0]) == int(parts[2])
        except ValueError:
            return False
    return False


def compare_metadata(
    root: Path,
    base: str,
    *,
    offline: bool,
    warnings: list[str] | None = None,
) -> list[str]:
    """Compare current governance metadata with the exact requested base."""
    root = root.resolve()
    errors: list[str] = []
    warnings = warnings if warnings is not None else []
    current_map = _read_current(root, TWIN_MAP_PATH)
    current_baseline = _read_current(root, LEDGER_BASELINE_PATH)
    current_registry = _read_current_dispositions(root)
    _validate_twin_map(current_map, TWIN_MAP_PATH)
    _validate_baseline(current_baseline, LEDGER_BASELINE_PATH)
    _validate_dispositions(current_registry, DISPOSITIONS_PATH)
    for disposition in current_registry["dispositions"]:
        if (disposition["type"] == "experimental"
                and date.fromisoformat(disposition["expires_on"]) < date.today()):
            errors.append(
                f"{DISPOSITIONS_PATH}: experimental disposition expired on {disposition['expires_on']}: {disposition['identity']}"
            )
    current_sets = parity_ledger.semantic_authority(root)
    current_manifest = parity_ledger.authority_manifest(current_sets)
    current_scan_map = parity_ledger.build_compact_twin_map(root)
    current_scan_map["exemptions"] = current_registry["dispositions"]
    current_scan = parity_ledger.scan(root, current_scan_map)

    old_map = _read_base(root, base, TWIN_MAP_PATH)
    old_baseline = _read_base(root, base, LEDGER_BASELINE_PATH)
    old_registry = _read_base(root, base, DISPOSITIONS_PATH)
    if old_registry is None:
        old_registry = {"schema_version": 1, "dispositions": []}
    _validate_dispositions(old_registry, f"{base}:{DISPOSITIONS_PATH}")
    new_exemptions: list[dict] = []
    active_exemptions: list[dict] = []
    if old_map is not None:
        _validate_twin_map(old_map, f"{base}:{TWIN_MAP_PATH}")
        with _base_tree(root, base) as base_root:
            base_sets = parity_ledger.semantic_authority(base_root)
            base_manifest = parity_ledger.authority_manifest(base_sets)
            if old_map["authority"] != base_manifest:
                errors.append(
                    f"{TWIN_MAP_PATH}: base authority cannot be reproduced with the current derivation; migration required"
                )
            base_scan_map = parity_ledger.build_compact_twin_map(base_root)
            base_scan = parity_ledger.scan(base_root, base_scan_map)
        base_findings = {item.identity for item in base_scan.findings}
        current_findings = {item.identity for item in current_scan.findings}
        required = _required_v3_exemptions(
            base_sets,
            current_sets,
            base_findings,
            current_findings,
        )
        if current_map["authority"] != current_manifest:
            if current_map["authority"] == old_map["authority"]:
                warnings.append(
                    f"{TWIN_MAP_PATH}: debt decreased; checked authority may be cleaned up later"
                )
            else:
                errors.append(
                    f"{TWIN_MAP_PATH}: authority matches neither the current tree nor the exact base"
                )
        for name, value in current_scan.counters.items():
            old_value = base_scan.counters.get(name, 0)
            if value > old_value:
                required.add(("add-counter", f"{name}\u0000{old_value}\u0000{value}"))
        current_by_key = {
            (item["kind"], item["identity"]): item
            for item in current_registry["dispositions"]
        }
        old_by_key = {
            (item["kind"], item["identity"]): item
            for item in old_registry["dispositions"]
        }
        inherited: set[tuple[str, str]] = set()
        for key, old_item in old_by_key.items():
            applied_at_base = _exemption_applies(
                key, base_sets, base_findings, base_scan.counters,
                base_scan.bootstrap_unpaired_debts,
            )
            applies_now = _exemption_applies(
                key, current_sets, current_findings, current_scan.counters,
                current_scan.bootstrap_unpaired_debts,
            )
            current_item = current_by_key.get(key)
            if applied_at_base and applies_now and current_item is None:
                errors.append(f"{TWIN_MAP_PATH}: inherited exemption was removed {key[0]} {key[1]}")
            elif applied_at_base and applies_now and current_item != old_item:
                errors.append(f"{TWIN_MAP_PATH}: inherited exemption changed {key[0]} {key[1]}")
            elif applied_at_base and applies_now:
                inherited.add(key)
            elif current_item is not None and not applies_now:
                warnings.append(
                    f"{DISPOSITIONS_PATH}: obsolete disposition {key[0]} {key[1]}; cleanup is optional"
                )
            elif current_item is not None and applies_now:
                warnings.append(
                    f"{DISPOSITIONS_PATH}: obsolete disposition cannot authorize reintroduced debt {key[0]} {key[1]}"
                )
        checked = {
            key for key in current_by_key
            if key not in old_by_key or key in inherited
        }
        for kind, identity in sorted(required - checked):
            errors.append(
                f"{TWIN_MAP_PATH}: derived inventory changed without an exact issue-bound authority change: {kind} {identity}"
            )
        for kind, identity in sorted(checked - required - inherited - set(old_by_key)):
            warnings.append(
                f"{DISPOSITIONS_PATH}: obsolete disposition {kind} {identity}; cleanup is optional"
            )
        new_exemptions = [
            item for key, item in current_by_key.items()
            if key not in old_by_key and key in required
        ]
        active_exemptions = [
            item for key, item in current_by_key.items()
            if key in inherited or key in required
        ]
    elif old_map is None:
        if current_map["authority"] != current_manifest:
            errors.append(f"{TWIN_MAP_PATH}: authority does not match independently derived current semantic sets")
        dispositions = current_registry["dispositions"]
        if dispositions:
            errors.append(
                f"{DISPOSITIONS_PATH}: bootstrap cannot introduce dispositions; "
                "add issue-bound authority in a later reviewed change"
            )

    if old_baseline is not None:
        _validate_baseline(old_baseline, f"{base}:{LEDGER_BASELINE_PATH}")

    if not offline:
        issues = _issues(current_baseline) | _issues(active_exemptions)
        payloads = {issue: _fetch_issue(issue) for issue in sorted(issues)}
        for issue, payload in payloads.items():
            if not _issue_payload_matches(issue, payload):
                errors.append(f"issue {issue} does not exist or is not accessible")
        for disposition in active_exemptions:
            if disposition["type"] != "experimental":
                continue
            issue = issue_ref.parse_current(disposition["issue"])
            if (payloads.get(issue) or {}).get("state") != "open":
                errors.append(f"experimental disposition issue {issue} must remain open")
        base_created_at = _git(root, ["show", "-s", "--format=%cI", base])
        for exemption in new_exemptions:
            if exemption["type"] == "platform_specific":
                continue
            issue = issue_ref.parse_current(exemption["issue"])
            if not _exemption_payload_is_bound(
                issue, payloads.get(issue), exemption["identity_sha256"], base_created_at
            ):
                errors.append(
                    f"issue {issue} is not fresh after the base or lacks the exact identity-hash marker"
                )
    return errors


def repository_consistency_errors(
    root: Path, *, warnings: list[str] | None = None
) -> list[str]:
    """Reject current-tree regressions while allowing proven debt reductions."""
    root = root.resolve()
    warnings = warnings if warnings is not None else []
    twin_map = _read_current(root, TWIN_MAP_PATH)
    baseline = _read_current(root, LEDGER_BASELINE_PATH)
    registry = _read_current_dispositions(root)
    _validate_twin_map(twin_map, TWIN_MAP_PATH)
    _validate_baseline(baseline, LEDGER_BASELINE_PATH)
    _validate_dispositions(registry, DISPOSITIONS_PATH)
    scan_map = parity_ledger.build_compact_twin_map(root)
    scan_map["exemptions"] = registry["dispositions"]
    result = parity_ledger.scan(root, scan_map)
    errors = [finding.output() for finding in result.errors]
    current = parity_ledger.build_compact_baseline(result)
    checked_groups = {
        (item["rule"], item["scope"]): item
        for item in baseline["accepted_findings"]
    }
    current_groups = {
        (item["rule"], item["scope"]): item
        for item in current["accepted_findings"]
    }
    for key in sorted(set(checked_groups) | set(current_groups)):
        old = checked_groups.get(key)
        new = current_groups.get(key)
        label = "|".join(key)
        if old is None:
            errors.append(f"{LEDGER_BASELINE_PATH}: new accepted finding group {label}")
        elif new is None or new["count"] < old["count"]:
            warnings.append(f"{LEDGER_BASELINE_PATH}: debt decreased in {label}; cleanup is optional")
        elif new["count"] > old["count"] or new["identities_sha256"] != old["identities_sha256"]:
            errors.append(f"{LEDGER_BASELINE_PATH}: accepted finding group regressed {label}")
    for name, value in result.counters.items():
        old_value = baseline["counters"].get(name, 0)
        if value > old_value:
            errors.append(f"{LEDGER_BASELINE_PATH}: counter {name} increased from {old_value} to {value}")
        elif value < old_value:
            warnings.append(f"{LEDGER_BASELINE_PATH}: counter {name} decreased from {old_value} to {value}; cleanup is optional")
    return errors


def _print_errors(errors: Iterable[str]) -> int:
    errors = list(errors)
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    print(f"parity governance ratchet: errors={len(errors)}")
    return 1 if errors else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--base", help="base ref; defaults durably to origin/main")
    parser.add_argument("--offline", action="store_true", help="skip GitHub issue existence checks")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        base = resolve_base(root, args.base)
        warnings: list[str] = []
        errors = repository_consistency_errors(root, warnings=warnings)
        errors.extend(compare_metadata(root, base, offline=args.offline, warnings=warnings))
        for warning in warnings:
            print(f"WARNING: {warning}", file=sys.stderr)
        return _print_errors(errors)
    except (RatchetError, issue_ref.IssueRefError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
