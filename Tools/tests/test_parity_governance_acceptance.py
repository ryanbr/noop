"""Acceptance tests for the product-free parity governance foundation."""

from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


TOOLS = Path(__file__).resolve().parents[1]
REPOSITORY = TOOLS.parent
sys.path.insert(0, str(TOOLS))

import issue_ref  # noqa: E402
import parity_ledger  # noqa: E402
import parity_ratchet  # noqa: E402


class IssueReferenceTests(unittest.TestCase):
    def test_current_metadata_requires_repository_qualified_references(self) -> None:
        reference = issue_ref.parse_current("bhelm/noop#17")
        self.assertEqual(("bhelm/noop", 17), (reference.repo, reference.number))
        for invalid in (17, True, "#17", " bhelm/noop#17", "bhelm/noop#0"):
            with self.subTest(invalid=invalid), self.assertRaises(issue_ref.IssueRefError):
                issue_ref.parse_current(invalid)

    def test_repository_is_part_of_issue_identity(self) -> None:
        self.assertNotEqual(
            issue_ref.parse_current("bhelm/noop#17"),
            issue_ref.parse_current("other/noop#17"),
        )


class RepositoryBaselineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # These acceptance tests all inspect one immutable checkout. Build the
        # repository evidence once for the class instead of paying for the same
        # full-tree parse in every assertion. This is test-local state, not a
        # persistent production cache; normal scanner calls still read fresh.
        cls.compact_map = parity_ledger._load_json(TOOLS / "parity_twin_map.json", {})
        cls.baseline = parity_ledger._load_json(TOOLS / "parity_ledger_baseline.json", {})
        cls.snapshot = parity_ledger._SourceSnapshot()
        cls.inventory = parity_ledger._inventory(REPOSITORY, cls.snapshot)
        (
            cls.swift_files,
            cls.kotlin_files,
            cls.swift_functions,
            cls.kotlin_functions,
            _swift_properties,
            _kotlin_properties,
            _swift_constants,
            _kotlin_constants,
        ) = cls.inventory
        _reference_files, declarations = parity_ledger._reference_declarations(
            REPOSITORY,
            cls.inventory[2:6],
            cls.snapshot,
        )
        cls.repo_swift_functions = [
            item for item in declarations
            if item.language == "swift" and item.kind == "function"
        ]
        cls.repo_kotlin_functions = [
            item for item in declarations
            if item.language == "kotlin" and item.kind == "function"
        ]
        cls.references = (
            parity_ledger.parse_twin_references(
                REPOSITORY, cls.swift_files, "swift", cls.swift_functions, cls.snapshot
            )
            + parity_ledger.parse_twin_references(
                REPOSITORY, cls.kotlin_files, "kotlin", cls.kotlin_functions, cls.snapshot
            )
        )
        cls.resolutions = parity_ledger.attached_function_resolutions(
            cls.references, cls.repo_swift_functions, cls.repo_kotlin_functions
        )
        cls.expanded_map = parity_ledger.build_twin_map(
            REPOSITORY, cls.inventory, cls.snapshot
        )
        cls.authority = parity_ledger.authority_manifest(
            parity_ledger.semantic_authority(
                REPOSITORY,
                expanded=cls.expanded_map,
                inventory=cls.inventory,
                snapshot=cls.snapshot,
            )
        )
        cls.result = parity_ledger.scan(REPOSITORY, cls.compact_map)

    def test_repository_has_one_typed_manual_disposition_registry(self) -> None:
        registry = parity_ledger._load_json(TOOLS / "parity_dispositions.json", {})
        parity_ratchet._validate_dispositions(registry, "fixture")
        self.assertEqual(1, registry["schema_version"])
        self.assertNotIn("exemptions", parity_ledger._load_json(TOOLS / "parity_twin_map.json", {}))

    def test_core_tools_stays_unfiltered_while_governance_is_path_filtered(self) -> None:
        core = (REPOSITORY / ".github/workflows/tools-python.yml").read_text(
            encoding="utf-8"
        )
        governance = (REPOSITORY / ".github/workflows/parity-governance.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("pull_request:\n    branches: [main]", core)
        self.assertNotIn("paths:", core)
        self.assertNotIn("unittest discover -s tests", core)
        self.assertIn("pull_request:\n    branches: [main]\n    paths:", governance)
        self.assertIn("'Tools/parity_*.py'", governance)
        self.assertNotIn("'Packages/**/*.swift'", governance)
        self.assertNotIn("'android/**/*.kt'", governance)
        self.assertIn("unittest discover -s tests", governance)

    def test_checked_in_inventory_and_baseline_match_current_sources(self) -> None:
        self.assertEqual([], self.result.errors)
        self.assertEqual([], parity_ledger.compact_baseline_drift(self.result, self.baseline))
        self.assertEqual(self.result.counters, self.baseline["counters"])

    def test_checked_metadata_is_compact_v3_and_expands_losslessly(self) -> None:
        self.assertEqual(3, self.compact_map["schema_version"])
        self.assertEqual(self.compact_map["authority"], self.authority)
        self.assertNotIn("unpaired_functions", self.compact_map)
        self.assertNotIn("constant_pairs", self.compact_map)

        self.assertEqual(3, self.baseline["schema_version"])
        self.assertNotIn("findings", self.baseline)
        self.assertTrue(self.baseline["accepted_findings"])
        for group in self.baseline["accepted_findings"]:
            self.assertTrue(group["reason"].strip())
            self.assertTrue(group["provenance"].strip())
            self.assertGreater(group["count"], 0)
            self.assertRegex(group["identities_sha256"], r"^[0-9a-f]{64}$")

    def test_v3_authority_schema_is_exact_and_canonically_ordered(self) -> None:
        compact = self.compact_map
        self.assertEqual(
            list(parity_ledger.SEMANTIC_AUTHORITY_SETS), list(compact["authority"])
        )
        parity_ratchet._validate_twin_map(compact, "fixture")

        malformed = json.loads(json.dumps(compact))
        malformed["authority"]["unknown"] = {"count": 0, "sha256": "0" * 64}
        with self.assertRaisesRegex(parity_ratchet.RatchetError, "every semantic set exactly"):
            parity_ratchet._validate_twin_map(malformed, "fixture")

        unknown = json.loads(json.dumps(compact))
        unknown["ignored_override"] = True
        with self.assertRaisesRegex(parity_ratchet.RatchetError, "top-level keys"):
            parity_ratchet._validate_twin_map(unknown, "fixture")

        misleading = json.loads(json.dumps(compact))
        misleading["scope"]["swift_roots"] = ["Elsewhere"]
        with self.assertRaisesRegex(parity_ratchet.RatchetError, "exact derivation roots"):
            parity_ratchet._validate_twin_map(misleading, "fixture")

        tampered = json.loads(json.dumps(self.baseline))
        tampered["accepted_findings"][0]["reason"] = "arbitrary non-empty replacement"
        with self.assertRaisesRegex(parity_ratchet.RatchetError, "canonical reviewed reason"):
            parity_ratchet._validate_baseline(tampered, "fixture")

    def test_repository_metadata_uses_invariants_not_frozen_counts_or_commits(self) -> None:
        for relative in ("parity_twin_map.json", "parity_ledger_baseline.json"):
            value = json.loads((TOOLS / relative).read_text(encoding="utf-8"))
            issue_ref.validate_current_issue_fields(value, relative)
            self.assertNotIn("expected_count", json.dumps(value))
            self.assertNotIn("source_commit", json.dumps(value))

    def test_checked_function_pairs_equal_current_attached_source_claims(self) -> None:
        declared = set(
            parity_ledger.resolved_attached_function_pairs(
                self.references, self.repo_swift_functions, self.repo_kotlin_functions
            )
        )
        checked = {
            (item["swift"], item["kotlin"])
            for item in self.expanded_map["function_pairs"]
        }
        self.assertEqual(declared, checked)
        declared_files = parity_ledger.resolved_file_pairs(
            declared, self.repo_swift_functions, self.repo_kotlin_functions
        )
        checked_files = {
            (item["swift"], item["kotlin"])
            for item in self.expanded_map["file_pairs"]
        }
        self.assertEqual(declared_files, checked_files)

    def test_every_nonunique_attached_claim_has_one_explicit_finding(self) -> None:
        unresolved_sites = {
            (reference.path, reference.line)
            for reference, candidates in self.resolutions.items()
            if len(candidates) != 1
        }
        finding_sites = {
            (finding.path, finding.line)
            for finding in self.result.findings
            if finding.rule in {
                "unresolved-attached-function-claim",
                "ambiguous-attached-function-claim",
            }
        }
        self.assertEqual(unresolved_sites, finding_sites)

    def test_repository_has_only_correct_collapse_pair_and_no_rank_waiver(self) -> None:
        pairs = {
            (item["swift"], item["kotlin"])
            for item in self.expanded_map["function_pairs"]
        }
        wrong = (
            "Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift::collapseOverCount/4#1",
            "android/app/src/main/java/com/noop/analytics/HrvAnalyzer.kt::collapsedCoverage/3#1",
        )
        correct = (
            "Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift::collapseOverCount/4#1",
            "android/app/src/main/java/com/noop/analytics/HrvAnalyzer.kt::collapseOverCount/4#1",
        )
        self.assertNotIn(wrong, pairs)
        self.assertIn(correct, pairs)
        kotlin_targets = [kotlin for _swift, kotlin in pairs]
        self.assertEqual(len(kotlin_targets), len(set(kotlin_targets)))

        self.assertFalse(any(
            "TestCentreLayout.swift::rank/1#1" in item.identity
            for item in self.result.findings
        ))

    def test_checked_constant_pairs_equal_current_dynamic_pairs(self) -> None:
        swift_constants, kotlin_constants = self.inventory[6:8]
        file_pairs = {
            (item["swift"], item["kotlin"])
            for item in self.expanded_map["file_pairs"]
        }
        dynamic, _ambiguous = parity_ledger._constant_pairing(
            swift_constants, kotlin_constants, file_pairs
        )
        resolved = {(swift.key, kotlin.key) for swift, kotlin in dynamic}
        checked = {
            (item["swift"], item["kotlin"])
            for item in self.expanded_map["constant_pairs"]
        }
        self.assertEqual(resolved, checked)


class GovernanceRatchetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.email", "tests@example.invalid"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.name", "Tests"], cwd=self.root, check=True)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write(self, relative: str, value: object) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")

    def commit(self) -> str:
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-qm", "base"], cwd=self.root, check=True)
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.root, text=True).strip()

    def experimental_registry(self, identity: str, issue: str = "bhelm/noop#78") -> dict:
        return {"schema_version": 1, "dispositions": [{
            "type": "experimental", "kind": "add-unpaired-function",
            "identity": identity, "platform": identity.split("\0", 1)[0],
            "identity_sha256": parity_ledger._canonical_sha256(identity),
            "issue": issue, "reason": "Time-boxed synthetic experiment awaiting its parity implementation.",
            "expires_on": "2026-12-31",
        }]}

    def test_typed_dispositions_require_explicit_platform_and_lifecycle_fields(self) -> None:
        experimental = {
            "schema_version": 1,
            "dispositions": [{
                "type": "experimental", "kind": "add-unpaired-function",
                "identity": "swift\0Engine.swift::trial/0#1", "platform": "swift",
                "identity_sha256": parity_ledger._canonical_sha256("swift\0Engine.swift::trial/0#1"),
                "issue": "bhelm/noop#78", "reason": "Time-boxed experiment awaiting parity decision.",
                "expires_on": "2026-12-31",
            }],
        }
        parity_ratchet._validate_dispositions(experimental, "fixture")
        malformed = json.loads(json.dumps(experimental))
        del malformed["dispositions"][0]["expires_on"]
        with self.assertRaisesRegex(parity_ratchet.RatchetError, "expires_on"):
            parity_ratchet._validate_dispositions(malformed, "fixture")

        platform_specific = {
            "schema_version": 1,
            "dispositions": [{
                "type": "platform_specific", "kind": "add-unpaired-function",
                "identity": "kotlin\0Engine.kt::androidOnly/0#1", "platform": "kotlin",
                "identity_sha256": parity_ledger._canonical_sha256("kotlin\0Engine.kt::androidOnly/0#1"),
                "rationale": "Uses an Android-only operating-system capability with no iOS equivalent.",
            }],
        }
        parity_ratchet._validate_dispositions(platform_specific, "fixture")

    def test_bootstrap_refuses_to_overwrite_existing_authority(self) -> None:
        tools = self.root / "Tools"
        tools.mkdir()
        map_path = tools / "parity_twin_map.json"
        baseline_path = tools / "parity_ledger_baseline.json"
        map_path.write_bytes(b"map-old-bytes\n")
        baseline_path.write_bytes(b"baseline-old-bytes\n")
        output = io.StringIO()
        with mock.patch("sys.stdout", output):
            code = parity_ledger.main([
                "--root", str(self.root), "--bootstrap-map", "--write-baseline",
            ])
        self.assertEqual(2, code)
        self.assertIn("initial authority creation only", output.getvalue())
        self.assertEqual(b"map-old-bytes\n", map_path.read_bytes())
        self.assertEqual(b"baseline-old-bytes\n", baseline_path.read_bytes())

    def test_bootstrap_and_baseline_flags_are_inseparable(self) -> None:
        for flag in ("--bootstrap-map", "--write-baseline"):
            with self.subTest(flag=flag):
                output = io.StringIO()
                with mock.patch("sys.stdout", output):
                    code = parity_ledger.main(["--root", str(self.root), flag])
                self.assertEqual(2, code)
                self.assertIn("must be used together", output.getvalue())
                self.assertFalse((self.root / "Tools/parity_twin_map.json").exists())
                self.assertFalse((self.root / "Tools/parity_ledger_baseline.json").exists())

    def test_bootstrap_scan_exception_preserves_prior_absence(self) -> None:
        with mock.patch.object(parity_ledger, "scan", side_effect=RuntimeError("synthetic scan failure")):
            with self.assertRaisesRegex(RuntimeError, "synthetic scan failure"):
                parity_ledger.main([
                    "--root", str(self.root), "--bootstrap-map", "--write-baseline",
                ])
        self.assertFalse((self.root / "Tools/parity_twin_map.json").exists())
        self.assertFalse((self.root / "Tools/parity_ledger_baseline.json").exists())

    def test_bootstrap_scan_error_preserves_prior_absence(self) -> None:
        finding = mock.Mock()
        finding.output.return_value = "synthetic scan error"
        result = mock.Mock(errors=[finding])
        output = io.StringIO()
        with mock.patch.object(parity_ledger, "scan", return_value=result), mock.patch("sys.stdout", output):
            code = parity_ledger.main([
                "--root", str(self.root), "--bootstrap-map", "--write-baseline",
            ])
        self.assertEqual(1, code)
        self.assertIn("snapshots unchanged", output.getvalue())
        self.assertFalse((self.root / "Tools/parity_twin_map.json").exists())
        self.assertFalse((self.root / "Tools/parity_ledger_baseline.json").exists())

    def test_bootstrap_publication_failure_rolls_back_both_files(self) -> None:
        real_replace = parity_ledger.os.replace
        calls = 0

        def fail_second(source, destination):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("synthetic second replace failure")
            return real_replace(source, destination)

        with mock.patch.object(parity_ledger.os, "replace", side_effect=fail_second):
            with self.assertRaisesRegex(OSError, "synthetic second replace failure"):
                parity_ledger.main([
                    "--root", str(self.root), "--bootstrap-map", "--write-baseline",
                ])
        self.assertFalse((self.root / "Tools/parity_twin_map.json").exists())
        self.assertFalse((self.root / "Tools/parity_ledger_baseline.json").exists())

    def test_refresh_restores_snapshots_when_new_debt_is_undisposed(self) -> None:
        swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift"
        kotlin = self.root / "android/app/src/main/java/com/noop/analytics/Engine.kt"
        swift.parent.mkdir(parents=True, exist_ok=True)
        kotlin.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text("enum Engine {}\n", encoding="utf-8")
        kotlin.write_text("object Engine {}\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        baseline = parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact))
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", baseline)
        self.write("Tools/parity_dispositions.json", {"schema_version": 1, "dispositions": []})
        base = self.commit()
        before_map = (self.root / "Tools/parity_twin_map.json").read_bytes()
        before_baseline = (self.root / "Tools/parity_ledger_baseline.json").read_bytes()
        before_dispositions = (self.root / "Tools/parity_dispositions.json").read_bytes()

        swift.write_text("enum Engine { static func accidentalDrift() {} }\n", encoding="utf-8")
        output = io.StringIO()
        with mock.patch("sys.stdout", output):
            code = parity_ledger.main([
                "--root", str(self.root), "--refresh-derived", "--base", base,
            ])
        self.assertEqual(1, code)
        self.assertIn("snapshots restored", output.getvalue())
        self.assertEqual(before_map, (self.root / "Tools/parity_twin_map.json").read_bytes())
        self.assertEqual(before_baseline, (self.root / "Tools/parity_ledger_baseline.json").read_bytes())
        self.assertEqual(before_dispositions, (self.root / "Tools/parity_dispositions.json").read_bytes())

    def test_expired_experimental_disposition_blocks(self) -> None:
        marker = self.root / "README"
        marker.write_text("base\n", encoding="utf-8")
        base = self.commit()
        compact = parity_ledger.build_compact_twin_map(self.root)
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact)))
        identity = "swift\0Example.swift::trial/0#1"
        registry = self.experimental_registry(identity)
        registry["dispositions"][0]["expires_on"] = "2020-01-01"
        self.write("Tools/parity_dispositions.json", registry)
        errors = parity_ratchet.compare_metadata(self.root, base, offline=True)
        self.assertTrue(any("experimental disposition expired" in error for error in errors), errors)

    def test_unreadable_base_blob_is_not_treated_as_absent_bootstrap_metadata(self) -> None:
        self.write("Tools/parity_twin_map.json", {"schema_version": 3})
        base = self.commit()
        real_check_output = parity_ratchet.subprocess.check_output

        def fail_only_show(arguments, **kwargs):
            if arguments[:2] == ["git", "show"]:
                raise subprocess.CalledProcessError(128, arguments, output="missing blob")
            return real_check_output(arguments, **kwargs)

        with mock.patch.object(
            parity_ratchet.subprocess, "check_output", side_effect=fail_only_show
        ):
            with self.assertRaisesRegex(parity_ratchet.RatchetError, "cannot read base"):
                parity_ratchet._read_base(
                    self.root, base, "Tools/parity_twin_map.json"
                )

    def test_regenerating_compact_map_and_baseline_cannot_accept_new_unpaired_source(self) -> None:
        swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift"
        kotlin = self.root / "android/app/src/main/java/com/noop/analytics/Engine.kt"
        swift.parent.mkdir(parents=True, exist_ok=True)
        kotlin.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text("enum Engine {}\n", encoding="utf-8")
        kotlin.write_text("object Engine {}\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        baseline = parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact))
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", baseline)
        base = self.commit()

        swift.write_text("enum Engine { static func newlyUnpaired() {} }\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        baseline = parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact))
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", baseline)

        errors = parity_ratchet.compare_metadata(self.root, base, offline=True)

        self.assertTrue(
            any("derived inventory changed without an exact issue-bound authority change" in error for error in errors),
            errors,
        )

    def test_regenerating_compact_metadata_cannot_accept_one_sided_constant(self) -> None:
        swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift"
        kotlin = self.root / "android/app/src/main/java/com/noop/analytics/Engine.kt"
        swift.parent.mkdir(parents=True, exist_ok=True)
        kotlin.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text("enum Engine {}\n", encoding="utf-8")
        kotlin.write_text("object Engine {}\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        baseline = parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact))
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", baseline)
        base = self.commit()

        swift.write_text("enum Engine { static let swiftOnlyLimit = 7 }\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        baseline = parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact))
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", baseline)

        errors = parity_ratchet.compare_metadata(self.root, base, offline=True)
        self.assertTrue(
            any("add-unpaired-constant" in error and "swiftOnlyLimit" in error for error in errors),
            errors,
        )

    def test_exact_compact_exemption_allows_only_its_current_delta(self) -> None:
        swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift"
        kotlin = self.root / "android/app/src/main/java/com/noop/analytics/Engine.kt"
        swift.parent.mkdir(parents=True, exist_ok=True)
        kotlin.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text("enum Engine {}\n", encoding="utf-8")
        kotlin.write_text("object Engine {}\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        baseline = parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact))
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", baseline)
        base = self.commit()

        swift.write_text("enum Engine { static func newlyUnpaired() {} }\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        identity = next(
            item for item in parity_ledger.semantic_authority(self.root)["unpaired_functions"]
            if "newlyUnpaired" in item
        )
        registry = self.experimental_registry(identity)
        self.write("Tools/parity_dispositions.json", registry)
        baseline = parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact))
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", baseline)
        self.assertEqual([], parity_ratchet.compare_metadata(self.root, base, offline=True))

        swift.write_text("enum Engine {}\n", encoding="utf-8")
        refreshed = parity_ledger.build_compact_twin_map(self.root)
        self.write("Tools/parity_twin_map.json", refreshed)
        self.write(
            "Tools/parity_ledger_baseline.json",
            parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, refreshed)),
        )
        warnings: list[str] = []
        errors = parity_ratchet.compare_metadata(
            self.root, base, offline=True, warnings=warnings
        )
        self.assertEqual([], errors)
        self.assertTrue(any("obsolete disposition" in warning for warning in warnings), warnings)
        with mock.patch.object(parity_ratchet, "_fetch_issue") as fetched:
            online_warnings: list[str] = []
            self.assertEqual(
                [],
                parity_ratchet.compare_metadata(
                    self.root, base, offline=False, warnings=online_warnings
                ),
            )
        fetched.assert_not_called()

    def test_platform_specific_disposition_allows_only_exact_one_sided_identity(self) -> None:
        swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift"
        kotlin = self.root / "android/app/src/main/java/com/noop/analytics/Engine.kt"
        swift.parent.mkdir(parents=True, exist_ok=True)
        kotlin.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text("enum Engine {}\n", encoding="utf-8")
        kotlin.write_text("object Engine {}\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact)))
        base = self.commit()

        kotlin.write_text("object Engine { fun androidOnly() = Unit }\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        identity = next(item for item in parity_ledger.semantic_authority(self.root)["unpaired_functions"] if "androidOnly" in item)
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact)))
        self.write("Tools/parity_dispositions.json", {"schema_version": 1, "dispositions": [{
            "type": "platform_specific", "kind": "add-unpaired-function",
            "identity": identity, "platform": "kotlin",
            "identity_sha256": parity_ledger._canonical_sha256(identity),
            "rationale": "Uses an Android-only operating-system capability with no iOS equivalent.",
        }]})
        self.assertEqual([], parity_ratchet.compare_metadata(self.root, base, offline=True))

    def test_debt_decrease_needs_no_metadata_rewrite_and_warns(self) -> None:
        swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift"
        kotlin = self.root / "android/app/src/main/java/com/noop/analytics/Engine.kt"
        swift.parent.mkdir(parents=True, exist_ok=True)
        kotlin.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text("enum Engine { static func oldDebt() {} }\n", encoding="utf-8")
        kotlin.write_text("object Engine {}\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        baseline = parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact))
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", baseline)
        base = self.commit()

        swift.write_text("enum Engine {}\n", encoding="utf-8")
        warnings: list[str] = []
        self.assertEqual(
            [],
            parity_ratchet.compare_metadata(
                self.root, base, offline=True, warnings=warnings
            ),
        )
        self.assertTrue(any("debt decreased" in warning for warning in warnings), warnings)

    def test_obsolete_inherited_exemption_cannot_authorize_reintroduction(self) -> None:
        swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift"
        kotlin = self.root / "android/app/src/main/java/com/noop/analytics/Engine.kt"
        swift.parent.mkdir(parents=True, exist_ok=True)
        kotlin.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text("enum Engine {}\n", encoding="utf-8")
        kotlin.write_text("object Engine {}\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        identity = "swift\0Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift::oldDebt/0#1"
        self.write("Tools/parity_dispositions.json", self.experimental_registry(identity))
        baseline = parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact))
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", baseline)
        base = self.commit()

        swift.write_text("enum Engine { static func oldDebt() {} }\n", encoding="utf-8")
        refreshed = parity_ledger.build_compact_twin_map(self.root)
        self.write("Tools/parity_twin_map.json", refreshed)
        self.write(
            "Tools/parity_ledger_baseline.json",
            parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, refreshed)),
        )
        errors = parity_ratchet.compare_metadata(self.root, base, offline=True)
        self.assertTrue(any("add-unpaired-function" in error and "oldDebt" in error for error in errors), errors)

    def test_removing_a_real_twin_claim_is_not_treated_as_debt_reduction(self) -> None:
        swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift"
        kotlin = self.root / "android/app/src/main/java/com/noop/analytics/Engine.kt"
        swift.parent.mkdir(parents=True, exist_ok=True)
        kotlin.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text(
            "enum Engine {\n    /// Kotlin twin: `Engine.score`.\n    static func score(_ value: Int) -> Int { value }\n}\n",
            encoding="utf-8",
        )
        kotlin.write_text(
            "object Engine { fun score(value: Int): Int = value }\n", encoding="utf-8"
        )
        compact = parity_ledger.build_compact_twin_map(self.root)
        self.write("Tools/parity_twin_map.json", compact)
        self.write(
            "Tools/parity_ledger_baseline.json",
            parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact)),
        )
        base = self.commit()

        swift.write_text(
            "enum Engine { static func score(_ value: Int) -> Int { value } }\n",
            encoding="utf-8",
        )
        refreshed = parity_ledger.build_compact_twin_map(self.root)
        self.write("Tools/parity_twin_map.json", refreshed)
        self.write(
            "Tools/parity_ledger_baseline.json",
            parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, refreshed)),
        )
        errors = parity_ratchet.compare_metadata(self.root, base, offline=True)
        self.assertTrue(any("remove-function-pair" in error for error in errors), errors)

    def test_lower_debt_count_cannot_mask_replacement_identity_in_ratchet(self) -> None:
        swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift"
        kotlin = self.root / "android/app/src/main/java/com/noop/analytics/Engine.kt"
        swift.parent.mkdir(parents=True, exist_ok=True)
        kotlin.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text(
            "enum Engine { static func oldOne() {}\n static func oldTwo() {} }\n",
            encoding="utf-8",
        )
        kotlin.write_text("object Engine {}\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        self.write("Tools/parity_twin_map.json", compact)
        self.write(
            "Tools/parity_ledger_baseline.json",
            parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact)),
        )
        base = self.commit()

        swift.write_text("enum Engine { static func replacement() {} }\n", encoding="utf-8")
        refreshed = parity_ledger.build_compact_twin_map(self.root)
        self.write("Tools/parity_twin_map.json", refreshed)
        self.write(
            "Tools/parity_ledger_baseline.json",
            parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, refreshed)),
        )
        errors = parity_ratchet.compare_metadata(self.root, base, offline=True)
        self.assertTrue(
            any("add-unpaired-function" in error and "replacement" in error for error in errors),
            errors,
        )

    def test_unchanged_inherited_exemption_stays_valid_without_refresh(self) -> None:
        swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift"
        kotlin = self.root / "android/app/src/main/java/com/noop/analytics/Engine.kt"
        swift.parent.mkdir(parents=True, exist_ok=True)
        kotlin.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text("enum Engine { static func inheritedDebt() {} }\n", encoding="utf-8")
        kotlin.write_text("object Engine {}\n", encoding="utf-8")
        compact = parity_ledger.build_compact_twin_map(self.root)
        identity = next(
            item for item in parity_ledger.semantic_authority(self.root)["unpaired_functions"]
            if "inheritedDebt" in item
        )
        self.write("Tools/parity_dispositions.json", self.experimental_registry(identity))
        baseline = parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact))
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", baseline)
        base = self.commit()

        self.assertEqual([], parity_ratchet.compare_metadata(self.root, base, offline=True))
        payload = {
            "number": 78,
            "repository_url": "https://api.github.com/repos/bhelm/noop",
            "html_url": "https://github.com/bhelm/noop/issues/78",
            "state": "open",
        }
        with mock.patch.object(parity_ratchet, "_fetch_issue", return_value=payload) as fetched:
            self.assertEqual([], parity_ratchet.compare_metadata(self.root, base, offline=False))
        fetched.assert_called_once()

    def test_bootstrap_on_base_without_governance_files_is_allowed(self) -> None:
        marker = self.root / "README"
        marker.write_text("base\n", encoding="utf-8")
        base = self.commit()
        compact = parity_ledger.build_compact_twin_map(self.root)
        self.write("Tools/parity_twin_map.json", compact)
        self.write("Tools/parity_ledger_baseline.json", parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact)))
        self.assertEqual([], parity_ratchet.compare_metadata(self.root, base, offline=True))

    def test_bootstrap_cannot_introduce_dispositions(self) -> None:
        marker = self.root / "README"
        marker.write_text("base\n", encoding="utf-8")
        base = self.commit()
        compact = parity_ledger.build_compact_twin_map(self.root)
        identity = "swift\0Example.swift::invented/0#1"
        self.write("Tools/parity_dispositions.json", self.experimental_registry(identity, "bhelm/noop#18"))
        self.write("Tools/parity_twin_map.json", compact)
        self.write(
            "Tools/parity_ledger_baseline.json",
            parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, compact)),
        )

        errors = parity_ratchet.compare_metadata(self.root, base, offline=True)

        self.assertTrue(any("bootstrap cannot introduce dispositions" in error for error in errors), errors)

    def test_same_issue_number_in_wrong_repository_fails_closed(self) -> None:
        ref = issue_ref.parse_current("bhelm/noop#77")
        response = subprocess.CompletedProcess(
            [], 0,
            json.dumps({
                "number": 77,
                "repository_url": "https://api.github.com/repos/other/noop",
                "html_url": "https://github.com/other/noop/issues/77",
            }),
            "",
        )
        with mock.patch.object(parity_ratchet.subprocess, "run", return_value=response):
            self.assertFalse(parity_ratchet.issue_exists(ref))

    def test_pull_request_and_ambiguous_response_fail_closed(self) -> None:
        ref = issue_ref.parse_current("bhelm/noop#77")
        for payload in (
            {"number": 77, "pull_request": {}, "html_url": "https://github.com/bhelm/noop/issues/77"},
            {"number": 77},
            {"number": True, "repository_url": "https://api.github.com/repos/bhelm/noop"},
        ):
            with self.subTest(payload=payload), mock.patch.object(
                parity_ratchet.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 0, json.dumps(payload), ""),
            ):
                self.assertFalse(parity_ratchet.issue_exists(ref))

    def test_exemption_issue_must_be_fresh_and_bind_exact_identity_hash(self) -> None:
        ref = issue_ref.parse_current("bhelm/noop#78")
        payload = {
            "number": 78,
            "repository_url": "https://api.github.com/repos/bhelm/noop",
            "html_url": "https://github.com/bhelm/noop/issues/78",
            "created_at": "2026-08-21T12:00:00Z",
            "state": "open",
            "body": "parity-governance-identity-sha256: " + "a" * 64,
        }
        response = subprocess.CompletedProcess([], 0, json.dumps(payload), "")
        with mock.patch.object(parity_ratchet.subprocess, "run", return_value=response):
            self.assertTrue(
                parity_ratchet.exemption_issue_is_bound(
                    ref, "a" * 64, "2026-08-21T11:00:00+00:00"
                )
            )
            self.assertFalse(
                parity_ratchet.exemption_issue_is_bound(
                    ref, "b" * 64, "2026-08-21T11:00:00+00:00"
                )
            )
            self.assertFalse(
                parity_ratchet.exemption_issue_is_bound(
                    ref, "a" * 64, "2026-08-21T13:00:00+00:00"
                )
            )
            payload["state"] = "closed"
            response = subprocess.CompletedProcess([], 0, json.dumps(payload), "")
            with mock.patch.object(parity_ratchet.subprocess, "run", return_value=response):
                self.assertFalse(
                    parity_ratchet.exemption_issue_is_bound(
                        ref, "a" * 64, "2026-08-21T11:00:00+00:00"
                    )
                )

    def test_default_base_is_exact_current_origin_main_not_an_old_merge_base(self) -> None:
        marker = self.root / "marker"
        marker.write_text("common\n", encoding="utf-8")
        common = self.commit()
        subprocess.run(["git", "checkout", "-qb", "candidate"], cwd=self.root, check=True)
        marker.write_text("candidate\n", encoding="utf-8")
        subprocess.run(["git", "commit", "-qam", "candidate"], cwd=self.root, check=True)
        subprocess.run(["git", "checkout", "-qb", "upstream", common], cwd=self.root, check=True)
        marker.write_text("upstream\n", encoding="utf-8")
        subprocess.run(["git", "commit", "-qam", "upstream"], cwd=self.root, check=True)
        upstream = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.root, text=True).strip()
        subprocess.run(["git", "update-ref", "refs/remotes/origin/main", upstream], cwd=self.root, check=True)
        subprocess.run(["git", "checkout", "-q", "candidate"], cwd=self.root, check=True)

        self.assertEqual(upstream, parity_ratchet.resolve_base(self.root, None))


if __name__ == "__main__":
    unittest.main()
