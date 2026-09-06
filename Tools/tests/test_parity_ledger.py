"""Acceptance tests for the cross-language parity ledger."""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

import parity_ledger  # noqa: E402


class ParityLedgerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift"
        self.kotlin = self.root / "android/app/src/main/java/com/noop/analytics/Engine.kt"
        self.swift.parent.mkdir(parents=True)
        self.kotlin.parent.mkdir(parents=True)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_clean_tree(self) -> None:
        self.swift.write_text(
            """public enum Engine {
    /// Kotlin twin: `Engine.score`.
    public static func score(_ value: Int) -> Int { value }
    public static let sampleLimit = 3
}
"""
        )
        self.kotlin.write_text(
            """object Engine {
    /** Swift twin: `Engine.score`. */
    fun score(value: Int): Int = value
    const val SAMPLE_LIMIT = 3
}
"""
        )

    def findings(self, twin_map: dict | None = None) -> list[parity_ledger.Finding]:
        if twin_map is None:
            twin_map = parity_ledger.build_twin_map(self.root)
        return parity_ledger.scan(self.root, twin_map).findings

    def run_cli(
        self,
        twin_map: dict,
        baseline: dict | None = None,
        *,
        no_baseline: bool = False,
        base: str | None = None,
    ) -> tuple[int, str]:
        map_path = self.root / "map.json"
        baseline_path = self.root / "baseline.json"
        map_path.write_text(json.dumps(twin_map))
        args = ["--root", str(self.root), "--map", str(map_path), "--baseline", str(baseline_path)]
        if baseline is not None:
            baseline_path.write_text(json.dumps(baseline))
        if no_baseline:
            args.append("--no-baseline")
        if base is not None:
            args.extend(["--base", base])
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = parity_ledger.main(args)
        return code, output.getvalue()

    def exit_code(self, twin_map: dict) -> int:
        return self.run_cli(twin_map, no_baseline=True)[0]

    def baseline_for(self, twin_map: dict) -> dict:
        return parity_ledger.build_compact_baseline(parity_ledger.scan(self.root, twin_map))

    def mark_current_tree_as_origin_main(self) -> None:
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(
            [
                "git", "-c", "user.name=Parity Test", "-c",
                "user.email=parity@example.invalid", "commit", "-qm", "base",
            ],
            cwd=self.root,
            check=True,
        )
        subprocess.run(["git", "branch", "origin/main", "HEAD"], cwd=self.root, check=True)

    def test_clean_synthetic_tree_has_no_findings(self) -> None:
        self.write_clean_tree()
        twin_map = parity_ledger.build_twin_map(self.root)
        self.assertEqual([], self.findings(twin_map))
        self.assertEqual(0, self.exit_code(twin_map))

    def test_compact_map_expands_losslessly_and_detects_source_drift(self) -> None:
        self.write_clean_tree()
        compact = parity_ledger.build_compact_twin_map(self.root)
        expanded, drift = parity_ledger.expand_twin_map(self.root, compact)
        self.assertEqual(3, compact["schema_version"])
        self.assertEqual([], drift)
        self.assertEqual(parity_ledger.build_twin_map(self.root), expanded)

        self.swift.write_text(self.swift.read_text() + "\npublic func addedAfterFreeze() {}\n")
        result = parity_ledger.scan(self.root, compact)
        self.assertIn("twin-map-authority-drift", {item.rule for item in result.findings})

    def test_compact_authority_drift_names_new_one_sided_declaration(self) -> None:
        self.write_clean_tree()
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(
            [
                "git", "-c", "user.name=Parity Test", "-c", "user.email=parity@example.invalid",
                "commit", "-qm", "fixture",
            ],
            cwd=self.root,
            check=True,
        )
        subprocess.run(["git", "branch", "origin/main", "HEAD"], cwd=self.root, check=True)
        compact = parity_ledger.build_compact_twin_map(self.root)
        baseline = self.baseline_for(compact)
        self.kotlin.write_text(
            self.kotlin.read_text()
            + "\nfun aFreshlyInventedOneSidedHelper(value: Int): Int = value\n"
        )
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(
            [
                "git", "-c", "user.name=Parity Test", "-c", "user.email=parity@example.invalid",
                "commit", "-qm", "add one-sided helper",
            ],
            cwd=self.root,
            check=True,
        )

        code, output = self.run_cli(compact, baseline)

        self.assertEqual(1, code)
        self.assertIn("add-unpaired-function", output)
        self.assertIn("kotlin", output)
        self.assertIn("android/app/src/main/java/com/noop/analytics/Engine.kt", output)
        self.assertIn("aFreshlyInventedOneSidedHelper/1#1", output)

    def test_protocol_and_oura_source_pairs_are_in_inventory_scope(self) -> None:
        self.assertIn("Packages/WhoopProtocol/Sources/**/*.swift", parity_ledger.SWIFT_GLOBS)
        self.assertIn("Packages/OuraProtocol/Sources/**/*.swift", parity_ledger.SWIFT_GLOBS)
        self.assertIn("android/app/src/main/java/com/noop/protocol/**/*.kt", parity_ledger.KOTLIN_GLOBS)
        self.assertIn("android/app/src/main/java/com/noop/oura/**/*.kt", parity_ledger.KOTLIN_GLOBS)
        self.write_clean_tree()
        scope = parity_ledger.build_compact_twin_map(self.root)["scope"]
        self.assertIn("Packages/StrandAnalytics/Sources", scope["swift_roots"])
        self.assertIn("android/app/src/main/java/com/noop/analytics", scope["kotlin_roots"])

    def test_repo_wide_line_comment_reference_is_checked_outside_inventory(self) -> None:
        self.write_clean_tree()
        strand = self.root / "Strand/Outside.swift"
        strand.parent.mkdir(parents=True)
        strand.write_text("// Kotlin twin: MissingOwner.missing\nfunc outside() {}\n")
        rules = {item.rule for item in self.findings() if item.path == "Strand/Outside.swift"}
        self.assertIn("dead-twin-reference", rules)

    def test_attached_claim_resolves_exact_counterpart_outside_authority_roots(self) -> None:
        self.swift.write_text("enum Engine {}\n")
        self.kotlin.write_text(
            """object Engine {
    /** Swift twin: `ExternalEngine.compute`. */
    fun compute(value: Int): Int = value
}
"""
        )
        strand = self.root / "Strand/ExternalEngine.swift"
        strand.parent.mkdir(parents=True, exist_ok=True)
        strand.write_text(
            "enum ExternalEngine { static func compute(_ value: Int) -> Int { value } }\n"
        )
        twin_map = parity_ledger.build_twin_map(self.root)
        result = parity_ledger.scan(self.root, twin_map)
        self.assertEqual([], result.errors)
        self.assertTrue(
            any("Strand/ExternalEngine.swift::compute/1#1" == item["swift"] for item in twin_map["function_pairs"])
        )

    def test_swift_package_module_qualifies_top_level_twin(self) -> None:
        swift = self.root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Summary.swift"
        swift.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text("public func summary(_ value: Int) -> Int { value }\n")
        self.kotlin.write_text(
            "/** Swift twin: `StrandAnalytics.summary`. */\n"
            "fun summary(value: Int): Int = value\n"
        )

        result = parity_ledger.scan(self.root, parity_ledger.build_twin_map(self.root))
        self.assertFalse(any(item.rule == "dead-twin-reference" for item in result.findings))
        self.assertEqual([], result.errors)

    def test_kotlin_constructor_property_resolves_owned_twin_reference(self) -> None:
        self.kotlin.write_text("data class LiveState(val historyReady: Boolean)\n")
        self.swift.write_text(
            "final class LiveState {\n"
            "    /// Kotlin twin: `LiveState.historyReady`.\n"
            "    var historyReady = false\n"
            "}\n"
        )

        result = parity_ledger.scan(self.root, parity_ledger.build_twin_map(self.root))
        self.assertFalse(any(item.rule == "dead-twin-reference" for item in result.findings))

    def test_android_test_reference_resolves_swift_strand_test_symbol(self) -> None:
        self.write_clean_tree()
        swift_test = self.root / "StrandTests/WorkoutSourceTests.swift"
        swift_test.parent.mkdir(parents=True)
        swift_test.write_text(
            "final class WorkoutSourceTests { func testPreservingCapturedCarriesStepsFromOld() {} }\n"
        )
        kotlin_test = self.root / "android/app/src/test/java/com/noop/ui/WorkoutEditingTest.kt"
        kotlin_test.parent.mkdir(parents=True)
        kotlin_test.write_text(
            "/** Twin of Swift `testPreservingCapturedCarriesStepsFromOld`. */\n"
            "fun preservingCapturedCarriesStepsFromOld() {}\n"
        )

        findings = [
            item for item in self.findings()
            if item.rule == "dead-twin-reference" and item.path.endswith("WorkoutEditingTest.kt")
        ]
        self.assertEqual([], findings)

    def test_new_one_sided_function_is_rejected(self) -> None:
        self.write_clean_tree()
        twin_map = parity_ledger.build_twin_map(self.root)
        self.swift.write_text(self.swift.read_text() + "\npublic func newlyAddedOnlyOnSwift(_ value: Int) -> Int { value }\n")
        rules = {finding.rule for finding in self.findings(twin_map)}
        self.assertIn("unmapped-function", rules)
        self.assertEqual(1, self.exit_code(twin_map))

    def test_trailing_comma_does_not_add_a_parameter(self) -> None:
        self.kotlin.write_text("fun score(first: Int, second: Int,) = first + second\n")
        declarations = parity_ledger.parse_functions(self.root, self.kotlin, "kotlin")
        self.assertEqual([("score", 2)], [(item.name, item.arity) for item in declarations])

    def test_generic_kotlin_extension_receivers_are_inventoried(self) -> None:
        self.kotlin.write_text(
            """fun Map<String, String>.cell(vararg keys: String) = ""
fun Map<String, String>.double(vararg keys: String) = 0.0
fun Map<String, String>.bool(vararg keys: String) = false
"""
        )
        declarations = parity_ledger.parse_functions(self.root, self.kotlin, "kotlin")
        self.assertEqual(["cell", "double", "bool"], [item.name for item in declarations])

    def test_computed_swift_and_kotlin_properties_are_paired(self) -> None:
        self.swift.write_text(
            """enum SleepStageTotals { struct Minutes {
    var asleep: Double { 1 }
    var inBed: Double { asleep + 1 }
} }
"""
        )
        self.kotlin.write_text(
            """object SleepStageTotals { data class Minutes(val awake: Double) {
    val asleep: Double get() = 1.0
    val inBed: Double
        get() { return asleep + 1.0 }
} }
"""
        )
        twin_map = parity_ledger.build_twin_map(self.root)
        self.assertEqual(2, len(twin_map["property_pairs"]))
        self.assertFalse(any(item.rule == "unmapped-property" for item in self.findings(twin_map)))

    def test_dead_twin_reference_is_rejected(self) -> None:
        self.write_clean_tree()
        self.swift.write_text(self.swift.read_text() + "\n/// Kotlin twin: `Engine.missingTarget`.\npublic func claimsMissingTwin() {}\n")
        twin_map = parity_ledger.build_twin_map(self.root)
        rules = {finding.rule for finding in self.findings(twin_map)}
        self.assertIn("dead-twin-reference", rules)
        self.assertEqual(1, self.exit_code(twin_map))

    def test_dead_and_unresolved_claims_cannot_be_generated_into_a_green_baseline(self) -> None:
        self.swift.write_text(
            """enum Engine {
    /// Kotlin twin: `Engine.missingTarget`.
    static func unresolvedClaim() {}
}
"""
        )
        self.kotlin.write_text("object Engine {}\n")
        compact = parity_ledger.build_compact_twin_map(self.root)
        result = parity_ledger.scan(self.root, compact)
        baseline = parity_ledger.build_compact_baseline(result)
        self.assertIn("dead-twin-reference", {item.rule for item in result.errors})
        self.assertIn("unresolved-attached-function-claim", {item.rule for item in result.errors})
        self.assertEqual(1, self.run_cli(compact, baseline)[0])

    def test_repeated_dead_reference_has_one_identity_per_claim_site(self) -> None:
        self.swift.write_text(
            """/// Kotlin twin: `MissingOwner.missing`.
public enum Engine {
    /// Kotlin twin: `MissingOwner.missing`.
    public static func score(_ value: Int) -> Int { value }
}
"""
        )
        self.kotlin.write_text("object Engine {}\n")

        # A baseline identity represents one claim site, not merely one target
        # string. Otherwise removing either claim is invisible to the ratchet.
        findings = [item for item in self.findings() if item.rule == "dead-twin-reference"]
        self.assertEqual(2, len(findings))
        self.assertEqual(2, len({item.identity for item in findings}))

    def test_only_nearest_function_twin_reference_attaches_to_declaration(self) -> None:
        self.swift.write_text(
            """enum Engine {
                /// Kotlin twin is `Engine.wrong`.
                /// Mirrors Kotlin `Engine.right`.
    static func claim(_ value: Int) -> Int { value }
}
"""
        )
        self.kotlin.write_text(
            """object Engine {
    fun wrong(value: Int): Int = value
    fun right(value: Int): Int = value
}
"""
        )

        twin_map = parity_ledger.build_twin_map(self.root)
        pairs = {
            (item["swift"], item["kotlin"])
            for item in twin_map["function_pairs"]
        }

        self.assertIn(
            (
                "Packages/StrandAnalytics/Sources/StrandAnalytics/Engine.swift::claim/1#1",
                "android/app/src/main/java/com/noop/analytics/Engine.kt::right/1#1",
            ),
            pairs,
        )
        self.assertFalse(any("::wrong/1#" in kotlin for _swift, kotlin in pairs))

    def test_file_twin_reference_is_not_attached_to_nearby_function(self) -> None:
        self.swift.write_text(
            """/// The Kotlin twin is Engine.kt and is covered by parity tests.
enum Engine {
    static func rank(_ value: Int) -> Int { value }
}
"""
        )
        self.kotlin.write_text("object Engine { fun rank(value: Int): Int = value }\n")

        twin_map = parity_ledger.build_twin_map(self.root)
        rules = {item.rule for item in self.findings(twin_map)}

        self.assertEqual([], twin_map["function_pairs"])
        self.assertNotIn("unresolved-attached-function-claim", rules)

    def test_swift_selector_label_disambiguates_same_arity_overload(self) -> None:
        self.swift.write_text(
            """enum Engine {
    static func from(hardwareId: String) -> Int { 1 }
    static func from(model: String) -> Int { 2 }
}
"""
        )
        self.kotlin.write_text(
            """object Engine {
    /** Twin of Swift `Engine.from(hardwareId:)`. */
    fun fromHardwareId(value: String): Int = 1
}
"""
        )
        twin_map = parity_ledger.build_twin_map(self.root)
        result = parity_ledger.scan(self.root, twin_map)
        self.assertNotIn(
            "ambiguous-attached-function-claim", {item.rule for item in result.findings}
        )
        self.assertTrue(any("::from/1#1" in item["swift"] for item in twin_map["function_pairs"]))

    def test_attached_claim_allows_exact_endpoints_with_different_arities(self) -> None:
        self.swift.write_text(
            """enum Engine {
    /// Kotlin twin: `Engine.score`.
    static func score(a: Int, b: Int, c: Int, d: Int) -> Int { a + b + c + d }
}
"""
        )
        self.kotlin.write_text(
            "object Engine { fun score(a: Int, b: Int, c: Int): Int = a + b + c }\n"
        )
        twin_map = parity_ledger.build_twin_map(self.root)
        result = parity_ledger.scan(self.root, twin_map)
        self.assertNotIn("unresolved-attached-function-claim", {item.rule for item in result.errors})
        self.assertEqual(1, len(twin_map["function_pairs"]))
        self.assertIn("::score/4#1", twin_map["function_pairs"][0]["swift"])
        self.assertIn("::score/3#1", twin_map["function_pairs"][0]["kotlin"])

    def test_attached_claim_rejects_stale_explicit_selector(self) -> None:
        self.swift.write_text(
            "enum Engine { static func score(actual: Int) -> Int { actual } }\n"
        )
        self.kotlin.write_text(
            """object Engine {
    /** Swift twin: `Engine.score(stale:)`. */
    fun score(value: Int): Int = value
}
"""
        )
        twin_map = parity_ledger.build_twin_map(self.root)
        result = parity_ledger.scan(self.root, twin_map)
        self.assertIn("unresolved-attached-function-claim", {item.rule for item in result.errors})
        self.assertEqual([], twin_map["function_pairs"])

    def test_ambiguous_attached_claim_is_an_unbaselinable_scan_error(self) -> None:
        self.swift.write_text(
            """enum Engine {
    static func score(first: Int) -> Int { first }
    static func score(second: Int) -> Int { second }
}
"""
        )
        self.kotlin.write_text(
            """object Engine {
    /** Swift twin: `Engine.score`. */
    fun score(value: Int): Int = value
}
"""
        )
        twin_map = parity_ledger.build_twin_map(self.root)
        result = parity_ledger.scan(self.root, twin_map)
        self.assertIn("ambiguous-attached-function-claim", {item.rule for item in result.errors})

    def test_normal_block_comment_reference_is_checked(self) -> None:
        self.write_clean_tree()
        self.kotlin.write_text(self.kotlin.read_text() + "\n/* Swift twin: MissingOwner.nope */\nfun claimant() = 1\n")
        self.assertTrue(any(item.rule == "dead-twin-reference" for item in self.findings()))

    def test_attached_reference_retarget_to_existing_function_invalidates_frozen_map(self) -> None:
        self.swift.write_text(
            """public enum Engine {
    /// Kotlin twin: `Engine.score`.
    public static func score(_ value: Int) -> Int { value }
}
"""
        )
        self.kotlin.write_text(
            """object Engine {
    fun score(value: Int): Int = value
    fun other(value: Int): Int = value
}
"""
        )
        frozen_map = parity_ledger.build_twin_map(self.root)
        self.swift.write_text(self.swift.read_text().replace("Engine.score", "Engine.other"))

        rules = {item.rule for item in self.findings(frozen_map)}

        self.assertIn("unmapped-declared-function-pair", rules)
        self.assertIn("stale-declared-function-pair", rules)

    def test_same_metadata_retarget_is_rescanned_from_current_content(self) -> None:
        self.swift.write_text(
            """public enum Engine {
    /// Kotlin twin: `Engine.score`.
    public static func score(_ value: Int) -> Int { value }
}
"""
        )
        self.kotlin.write_text(
            """object Engine {
    fun score(value: Int): Int = value
    fun other(value: Int): Int = value
}
"""
        )
        frozen_map = parity_ledger.build_twin_map(self.root)
        original_stat = self.swift.stat()
        original_size = original_stat.st_size

        self.swift.write_text(self.swift.read_text().replace("Engine.score", "Engine.other"))
        self.assertEqual(original_size, self.swift.stat().st_size)
        os.utime(self.swift, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))

        rules = {item.rule for item in self.findings(frozen_map)}
        self.assertIn("unmapped-declared-function-pair", rules)
        self.assertIn("stale-declared-function-pair", rules)

    def test_scan_uses_one_immutable_source_snapshot_per_file(self) -> None:
        self.write_clean_tree()
        twin_map = parity_ledger.build_twin_map(self.root)
        original_read = parity_ledger._read
        reads: list[Path] = []

        def recording_read(path: Path) -> str:
            reads.append(path)
            return original_read(path)

        with mock.patch.object(parity_ledger, "_read", side_effect=recording_read):
            parity_ledger.scan(self.root, twin_map)

        self.assertEqual(sorted([self.swift, self.kotlin]), sorted(reads))

    def test_retargeted_claims_cannot_hide_behind_stale_file_and_constant_pairs(self) -> None:
        swift_one = self.swift.with_name("One.swift")
        swift_two = self.swift.with_name("Two.swift")
        kotlin_one = self.kotlin.with_name("One.kt")
        kotlin_two = self.kotlin.with_name("Two.kt")
        swift_one.write_text(
            """enum Engine {
    static let limit = 1
}
enum SwiftOne {
    /// Kotlin twin: `KotlinOne.score`.
    static func score(_ value: Int) -> Int { value }
}
"""
        )
        swift_two.write_text(
            """enum Engine {
    static let limit = 2
}
enum SwiftTwo {
    /// Kotlin twin: `KotlinTwo.score`.
    static func score(_ value: Int) -> Int { value }
}
"""
        )
        kotlin_one.write_text(
            "object Engine { const val LIMIT = 1 }; object KotlinOne { fun score(value: Int): Int = value }\n"
        )
        kotlin_two.write_text(
            "object Engine { const val LIMIT = 2 }; object KotlinTwo { fun score(value: Int): Int = value }\n"
        )
        frozen_map = parity_ledger.build_twin_map(self.root)

        swift_one.write_text(swift_one.read_text().replace("KotlinOne.score", "KotlinTwo.score"))
        swift_two.write_text(swift_two.read_text().replace("KotlinTwo.score", "KotlinOne.score"))
        refreshed_map = parity_ledger.build_twin_map(self.root)
        stale_authority = json.loads(json.dumps(frozen_map))
        stale_authority["function_pairs"] = refreshed_map["function_pairs"]
        stale_authority["unpaired_functions"] = refreshed_map["unpaired_functions"]

        rules = {item.rule for item in self.findings(stale_authority)}

        self.assertIn("unmapped-declared-file-pair", rules)
        self.assertIn("stale-declared-file-pair", rules)
        self.assertTrue(
            {"unmapped-constant-pair", "stale-constant-pair", "constant-value-mismatch"}
            & rules,
            rules,
        )

    def test_attached_reference_removal_invalidates_frozen_map(self) -> None:
        self.swift.write_text(
            """public enum Engine {
    /// Kotlin twin: `Engine.score`.
    public static func score(_ value: Int) -> Int { value }
}
"""
        )
        self.kotlin.write_text("object Engine { fun score(value: Int): Int = value }\n")
        frozen_map = parity_ledger.build_twin_map(self.root)
        self.swift.write_text(self.swift.read_text().replace("    /// Kotlin twin: `Engine.score`.\n", ""))

        self.assertTrue(
            any(item.rule == "stale-declared-function-pair" for item in self.findings(frozen_map))
        )

    def test_new_attached_reference_requires_corresponding_map_pair(self) -> None:
        self.swift.write_text("public enum Engine { public static func score(_ value: Int) -> Int { value } }\n")
        self.kotlin.write_text("object Engine { fun score(value: Int): Int = value }\n")
        frozen_map = parity_ledger.build_twin_map(self.root)
        self.swift.write_text(
            """public enum Engine {
    /// Kotlin twin: `Engine.score`.
    public static func score(_ value: Int) -> Int { value }
}
"""
        )

        self.assertTrue(
            any(item.rule == "unmapped-declared-function-pair" for item in self.findings(frozen_map))
        )

    def test_stale_attached_reference_to_missing_target_remains_red(self) -> None:
        self.swift.write_text(
            """public enum Engine {
    /// Kotlin twin: `Engine.missing`.
    public static func score(_ value: Int) -> Int { value }
}
"""
        )
        self.kotlin.write_text("object Engine { fun score(value: Int): Int = value }\n")

        rules = {item.rule for item in self.findings()}
        self.assertIn("dead-twin-reference", rules)
        self.assertIn("unresolved-attached-function-claim", rules)

    def test_ambiguous_attached_reference_is_an_explicit_finding(self) -> None:
        self.swift.write_text(
            """public enum Engine {
    /// Kotlin twin: `Engine.score`.
    public static func claim(_ value: Int) -> Int { value }
}
"""
        )
        self.kotlin.write_text(
            """object Engine {
    fun score(value: Int): Int = value
    fun score(value: Int, extra: Int): Int = value + extra
}
"""
        )
        twin_map = parity_ledger.build_twin_map(self.root)

        self.assertTrue(
            any(
                item.rule == "ambiguous-attached-function-claim"
                for item in self.findings(twin_map)
            )
        )

    def test_qualified_reference_requires_the_actual_owner(self) -> None:
        self.swift.write_text("enum Bar { static func existingName() {} }\n")
        self.kotlin.write_text("// Swift twin: Foo.existingName\nfun claim() = 1\n")
        findings = self.findings()
        self.assertTrue(any(item.rule == "dead-twin-reference" for item in findings))

    def test_constant_expression_is_fully_evaluated(self) -> None:
        self.swift.write_text("enum Engine { static let hours = 48 * 3_600 }\n")
        self.kotlin.write_text("object Engine { const val HOURS = 48L * 3_600L }\n")
        twin_map = parity_ledger.build_twin_map(self.root)
        self.assertFalse(any(item.rule.startswith("constant-") for item in self.findings(twin_map)))
        self.kotlin.write_text("object Engine { const val HOURS = 48L * 3_601L }\n")
        self.assertTrue(any(item.rule == "constant-value-mismatch" for item in self.findings(twin_map)))

    def test_new_equal_mirrored_constant_pair_must_be_added_to_map(self) -> None:
        self.write_clean_tree()
        frozen_map = parity_ledger.build_twin_map(self.root)
        self.swift.write_text(
            self.swift.read_text().replace(
                "sampleLimit = 3", "sampleLimit = 3\n    public static let freshLimit = 7"
            )
        )
        self.kotlin.write_text(
            self.kotlin.read_text().replace(
                "SAMPLE_LIMIT = 3", "SAMPLE_LIMIT = 3\n    const val FRESH_LIMIT = 7"
            )
        )

        findings = self.findings(frozen_map)

        self.assertTrue(any(item.rule == "unmapped-constant-pair" for item in findings), findings)
        refreshed_map = parity_ledger.build_twin_map(self.root)
        self.assertFalse(
            any(item.rule == "unmapped-constant-pair" for item in self.findings(refreshed_map))
        )

    def test_new_one_sided_constant_is_not_assumed_to_be_a_twin(self) -> None:
        self.write_clean_tree()
        frozen_map = parity_ledger.build_twin_map(self.root)
        self.swift.write_text(
            self.swift.read_text().replace(
                "sampleLimit = 3", "sampleLimit = 3\n    public static let swiftOnlyLimit = 7"
            )
        )

        self.assertFalse(
            any(item.rule == "unmapped-constant-pair" for item in self.findings(frozen_map))
        )

    def test_numeric_expression_parser_consumes_every_supported_operator(self) -> None:
        parsed = parity_ledger._literal("-(2 - 50) * (7_200 / 2) + 0x10 - 0b1")
        self.assertEqual("number:172815", parsed[0])
        self.assertIsNone(parity_ledger._literal("48 * 3_600 trailing"))

    def test_unparseable_mapped_constant_is_reported(self) -> None:
        self.swift.write_text("enum Engine { static let limit = makeLimit() }\n")
        self.kotlin.write_text("object Engine { const val LIMIT = 3 }\n")
        twin_map = parity_ledger.build_twin_map(self.root)
        self.assertTrue(any(item.rule == "constant-unverifiable" for item in self.findings(twin_map)))

    def test_stale_constant_pair_is_reported_after_one_sided_rename(self) -> None:
        self.write_clean_tree()
        twin_map = parity_ledger.build_twin_map(self.root)
        self.kotlin.write_text(self.kotlin.read_text().replace("SAMPLE_LIMIT", "RENAMED_LIMIT"))

        stale = [item for item in self.findings(twin_map) if item.rule == "stale-constant-pair"]

        self.assertEqual(1, len(stale))
        self.assertIn("SAMPLE_LIMIT", stale[0].text)

    def test_resolvable_constant_pair_has_no_stale_finding(self) -> None:
        self.write_clean_tree()
        twin_map = parity_ledger.build_twin_map(self.root)

        self.assertFalse(any(item.rule == "stale-constant-pair" for item in self.findings(twin_map)))

    def test_constant_owner_disambiguates_same_normalized_name(self) -> None:
        self.swift.write_text("enum SedentaryDetector { static let defaultSmoothWindowS = 240.0 }\n")
        self.kotlin = self.kotlin.with_name("SedentaryDetector.kt")
        self.kotlin.write_text("object SedentaryDetector { const val DEFAULT_SMOOTH_WINDOW_S = 240.0 }\n")
        self.kotlin.with_name("NapDetector.kt").write_text(
            "object NapDetector { const val DEFAULT_SMOOTH_WINDOW_S = 120.0 }\n"
        )
        twin_map = parity_ledger.build_twin_map(self.root)
        pairs = twin_map["constant_pairs"]
        self.assertEqual(1, len(pairs))
        self.assertIn("SedentaryDetector", pairs[0]["kotlin"])
        self.assertFalse(any(item.rule == "constant-ambiguous" for item in self.findings(twin_map)))

    def test_remaining_constant_ambiguity_is_reported(self) -> None:
        self.swift.write_text("enum Engine { static let limit = 3 }\n")
        self.kotlin.write_text("object First { const val LIMIT = 3 }\n")
        self.kotlin.with_name("Second.kt").write_text("object Second { const val LIMIT = 3 }\n")
        twin_map = parity_ledger.build_twin_map(self.root)
        self.assertTrue(any(item.rule == "constant-ambiguous" for item in self.findings(twin_map)))

    def test_constant_value_mismatch_is_rejected(self) -> None:
        self.write_clean_tree()
        self.kotlin.write_text(self.kotlin.read_text().replace("SAMPLE_LIMIT = 3", "SAMPLE_LIMIT = 4"))
        twin_map = parity_ledger.build_twin_map(self.root)
        rules = {finding.rule for finding in self.findings(twin_map)}
        self.assertIn("constant-value-mismatch", rules)
        self.assertEqual(1, self.exit_code(twin_map))

    def test_same_metadata_constant_change_is_rescanned_from_current_content(self) -> None:
        self.write_clean_tree()
        twin_map = parity_ledger.build_twin_map(self.root)
        original_stat = self.kotlin.stat()
        original_size = original_stat.st_size

        self.kotlin.write_text(self.kotlin.read_text().replace("SAMPLE_LIMIT = 3", "SAMPLE_LIMIT = 4"))
        self.assertEqual(original_size, self.kotlin.stat().st_size)
        os.utime(self.kotlin, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))

        rules = {finding.rule for finding in self.findings(twin_map)}
        self.assertIn("constant-value-mismatch", rules)

    def test_platform_database_schema_versions_are_not_parity_twins(self) -> None:
        swift = self.root / "Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift"
        kotlin = self.root / "android/app/src/main/java/com/noop/data/WhoopDatabase.kt"
        swift.parent.mkdir(parents=True)
        kotlin.parent.mkdir(parents=True)
        swift.write_text("public enum WhoopStore { public static let schemaVersion = 18 }\n")
        kotlin.write_text("object WhoopDatabase { const val SCHEMA_VERSION = 31 }\n")

        twin_map = parity_ledger.build_twin_map(self.root)
        pairs = {(item["swift"], item["kotlin"]) for item in twin_map["constant_pairs"]}
        self.assertNotIn(
            (
                "Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift::schemaVersion",
                "android/app/src/main/java/com/noop/data/WhoopDatabase.kt::SCHEMA_VERSION",
            ),
            pairs,
        )
        constant_findings = [item for item in self.findings(twin_map) if item.rule.startswith("constant-")]
        self.assertEqual([], constant_findings)

    def test_test_only_wiring_is_rejected(self) -> None:
        self.write_clean_tree()
        self.swift.write_text(self.swift.read_text() + "\npublic func testOnlyHelper(_ value: Int) -> Int { value }\n")
        test_path = self.root / "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/EngineTests.swift"
        test_path.parent.mkdir(parents=True)
        test_path.write_text("func testHelper() { _ = testOnlyHelper(1) }\n")
        twin_map = parity_ledger.build_twin_map(self.root)
        rules = {finding.rule for finding in self.findings(twin_map)}
        self.assertIn("test-only-callsite", rules)
        self.assertEqual(1, self.exit_code(twin_map))

    def test_test_only_calls_use_owner_and_arity_and_ignore_extension_declaration(self) -> None:
        self.kotlin.write_text(
            """object Alpha { fun collide(first: Int, second: Int) = first + second }
object Beta { fun collide(value: Int) = value }
fun Map<String, String>.extensionOnly(value: Int) = value
fun production() = Alpha.collide(1, 2)
"""
        )
        test_path = self.root / "android/app/src/test/java/com/noop/analytics/EngineTest.kt"
        test_path.parent.mkdir(parents=True)
        test_path.write_text("fun testIt() { Beta.collide(1); Map.extensionOnly(1) }\n")
        findings = [item for item in self.findings() if item.rule == "test-only-callsite"]
        texts = "\n".join(item.text for item in findings)
        self.assertIn("Beta.collide/1", texts)
        self.assertIn("Map.extensionOnly/1", texts)
        self.assertNotIn("Alpha.collide/1", texts)

    def test_call_omitting_defaults_counts_as_production_callsite(self) -> None:
        self.kotlin.write_text(
            """object Roller { fun roll(rr: Int, windowSec: Int = 90, stepSec: Int = 0) = rr + windowSec + stepSec }
fun production() = Roller.roll(1)
"""
        )
        test_path = self.root / "android/app/src/test/java/com/noop/analytics/RollTest.kt"
        test_path.parent.mkdir(parents=True)
        test_path.write_text("fun testIt() { Roller.roll(1, 2, 3) }\n")
        texts = "\n".join(
            item.text for item in self.findings() if item.rule == "test-only-callsite"
        )
        self.assertNotIn("Roller.roll/3", texts)

    def test_call_cannot_omit_required_parameters(self) -> None:
        self.kotlin.write_text(
            """object Roller { fun roll(rr: Int, windowSec: Int, stepSec: Int) = rr + windowSec + stepSec }
fun unrelated() = Roller.roll(1)
"""
        )
        test_path = self.root / "android/app/src/test/java/com/noop/analytics/RollTest.kt"
        test_path.parent.mkdir(parents=True)
        test_path.write_text("fun testIt() { Roller.roll(1, 2, 3) }\n")
        texts = "\n".join(
            item.text for item in self.findings() if item.rule == "test-only-callsite"
        )
        self.assertIn("Roller.roll/3", texts)

    def test_unqualified_same_file_call_counts_despite_sibling_owner(self) -> None:
        self.kotlin.write_text(
            """object Verdict { fun verdict(value: Int) = value
    fun production() = verdict(1) }
"""
        )
        sibling = self.kotlin.parent / "Sibling.kt"
        sibling.write_text("object Sibling { fun verdict(first: Int, second: Int) = first + second }\n")
        test_path = self.root / "android/app/src/test/java/com/noop/analytics/VerdictTest.kt"
        test_path.parent.mkdir(parents=True)
        test_path.write_text("fun testIt() { Verdict.verdict(1); Sibling.verdict(1, 2) }\n")
        texts = "\n".join(
            item.text for item in self.findings() if item.rule == "test-only-callsite"
        )
        self.assertNotIn("Verdict.verdict/1", texts)
        self.assertIn("Sibling.verdict/2", texts)

    def test_exact_arity_match_wins_over_relaxed_overload(self) -> None:
        self.kotlin.write_text(
            """object Over { fun pick(value: Int) = value
    fun pick(value: Int, extra: Int = 0) = value + extra }
fun production() = Over.pick(1)
"""
        )
        test_path = self.root / "android/app/src/test/java/com/noop/analytics/OverTest.kt"
        test_path.parent.mkdir(parents=True)
        test_path.write_text("fun testIt() { Over.pick(1, 2) }\n")
        texts = "\n".join(
            item.text for item in self.findings() if item.rule == "test-only-callsite"
        )
        self.assertIn("Over.pick/2", texts)

    def test_lowercase_instance_receiver_resolves_like_unqualified(self) -> None:
        self.kotlin.write_text(
            """object Burst { fun codesWithTimes(first: Int, second: Int, extra: Int = 0) = first + second + extra }
object Assembler { val burst = Burst
    fun production(): Int { return burst.codesWithTimes(1, 2) } }
"""
        )
        test_path = self.root / "android/app/src/test/java/com/noop/analytics/BurstTest.kt"
        test_path.parent.mkdir(parents=True)
        test_path.write_text("fun testIt() { Burst.codesWithTimes(1, 2, 3) }\n")
        texts = "\n".join(
            item.text for item in self.findings() if item.rule == "test-only-callsite"
        )
        self.assertNotIn("Burst.codesWithTimes/3", texts)

    def test_same_file_resolution_prefers_the_lexical_owner(self) -> None:
        self.kotlin.write_text(
            """object First { fun add(value: Int) = value
    fun production() = add(1) }
object Second { fun add(value: Int) = value }
"""
        )
        test_path = self.root / "android/app/src/test/java/com/noop/analytics/AddTest.kt"
        test_path.parent.mkdir(parents=True)
        test_path.write_text("fun testIt() { Second.add(1) }\n")
        texts = "\n".join(
            item.text for item in self.findings() if item.rule == "test-only-callsite"
        )
        self.assertNotIn("First.add/1", texts)
        self.assertIn("Second.add/1", texts)

    def test_kotlin_call_inside_string_template_counts_as_production(self) -> None:
        self.kotlin.write_text(
            '''object Trace { fun suffix(value: Int) = value }
fun production(value: Int) = "trace=${Trace.suffix(value)}"
'''
        )
        test_path = self.root / "android/app/src/test/java/com/noop/analytics/TraceTest.kt"
        test_path.parent.mkdir(parents=True)
        test_path.write_text("fun testIt() { Trace.suffix(1) }\n")

        texts = "\n".join(
            item.text for item in self.findings() if item.rule == "test-only-callsite"
        )

        self.assertNotIn("Trace.suffix/1", texts)

    def test_kotlin_nested_templates_preserve_code_and_mask_nested_string_text(self) -> None:
        self.kotlin.write_text(
            r'''object Trace {
    fun suffix(value: Int) = value
    fun literalOnly(value: Int) = value
}
fun production(value: Int) =
    "outer ${run { if (value > 0) { "inner ${Trace.suffix(value)} noise=Trace.literalOnly(value) tab=\t dollar=\$" } else "none" }}"
'''
        )
        test_path = self.root / "android/app/src/test/java/com/noop/analytics/TraceTest.kt"
        test_path.parent.mkdir(parents=True)
        test_path.write_text(
            "fun testIt() { Trace.suffix(1); Trace.literalOnly(1) }\n"
        )

        texts = "\n".join(
            item.text for item in self.findings() if item.rule == "test-only-callsite"
        )

        self.assertNotIn("Trace.suffix/1", texts)
        self.assertIn("Trace.literalOnly/1", texts)

    def test_kotlin_string_arguments_keep_overload_arity_and_argument_positions(self) -> None:
        self.kotlin.write_text(
            r'''object Target {
    fun emit(value: Int) = value
    fun emit(value: Int, text: String) = text
    fun first(text: String, middle: Int, last: Int) = text
    fun middle(first: Int, text: String, last: Int) = text
    fun last(first: Int, middle: Int, text: String) = text
    fun nested(value: Int) = value
    fun literalOnly(value: Int) = value
}
fun production(value: String) {
    Target.emit(1, "outer ${value.ifEmpty { "fallback" }}")
    Target.first("plain literal", 2, 3)
    Target.middle(1, "plain literal", 3)
    Target.last(1, 2, "outer ${run { "inner ${Target.nested(4)}" }}")
    val noise = "Target.literalOnly(5)"
}
'''
        )
        test_path = self.root / "android/app/src/test/java/com/noop/analytics/TargetTest.kt"
        test_path.parent.mkdir(parents=True)
        test_path.write_text(
            """fun testIt(text: String) {
    Target.emit(1, text)
    Target.first(text, 2, 3)
    Target.middle(1, text, 3)
    Target.last(1, 2, text)
    Target.nested(4)
    Target.literalOnly(5)
}
"""
        )

        texts = "\n".join(
            item.text for item in self.findings() if item.rule == "test-only-callsite"
        )

        for signature in ("Target.emit/2", "Target.first/3", "Target.middle/3", "Target.last/3",
                          "Target.nested/1"):
            self.assertNotIn(signature, texts)
        self.assertIn("Target.literalOnly/1", texts)

    def test_kotlin_literal_comment_and_plain_malformed_strings_stay_masked(self) -> None:
        self.kotlin.write_text(
            r'''object Trace {
    fun literalOnly(value: Int) = value
    fun malformed(value: Int) = value
}
fun literal(value: Int): String {
    val plain = "Trace.literalOnly(value)"
    val escaped = "\${Trace.literalOnly(value)}"
    // ${Trace.literalOnly(value)
    /* nested /* ${Trace.literalOnly(value) */ comment */
    return plain + escaped
}
fun broken(value: Int) = "broken Trace.malformed(value)
'''
        )
        test_path = self.root / "android/app/src/test/java/com/noop/analytics/TraceTest.kt"
        test_path.parent.mkdir(parents=True)
        test_path.write_text(
            "fun testIt() { Trace.literalOnly(1); Trace.malformed(1) }\n"
        )

        result = parity_ledger.scan(self.root, parity_ledger.build_twin_map(self.root))
        texts = "\n".join(
            item.text for item in result.findings if item.rule == "test-only-callsite"
        )

        self.assertEqual([], result.errors)
        self.assertIn("Trace.literalOnly/1", texts)
        self.assertIn("Trace.malformed/1", texts)

    def test_unterminated_kotlin_template_is_a_stable_scan_error_and_cli_failure(self) -> None:
        self.kotlin.write_text(
            '''object Trace { fun suffix(value: Int) = value }
fun broken(value: Int) = "broken ${run { Trace.suffix(value) }
'''
        )
        twin_map = parity_ledger.build_twin_map(self.root)

        result = parity_ledger.scan(self.root, twin_map)
        errors = [error.output() for error in result.errors]

        self.assertEqual(
            [
                "android/app/src/main/java/com/noop/analytics/Engine.kt:2: "
                "malformed-kotlin-template: unterminated Kotlin string template"
            ],
            errors,
        )
        code, output = self.run_cli(twin_map, parity_ledger.build_compact_baseline(result))
        self.assertEqual(1, code)
        self.assertIn("FAIL 1 parity ledger scan error(s):", output)
        self.assertIn(errors[0], output)
        self.assertTrue(
            output.rstrip().endswith("Baseline not evaluated: 1 scan error."),
            output,
        )

    def test_invalid_utf8_is_a_stable_hard_error(self) -> None:
        self.write_clean_tree()
        twin_map = parity_ledger.build_twin_map(self.root)
        self.swift.write_bytes(b"enum Engine {\n\xff\n}\n")
        result = parity_ledger.scan(self.root, twin_map)
        self.assertEqual(["invalid-utf8"], [item.rule for item in result.errors])
        code, output = self.run_cli(twin_map, no_baseline=True)
        self.assertEqual(1, code)
        self.assertIn("invalid-utf8", output)

    def test_artificial_duplicate_is_rejected(self) -> None:
        self.write_clean_tree()
        extra = self.swift.with_name("Other.swift")
        extra.write_text("public func dayString(_ value: Int) -> String { \"x\" }\n")
        self.swift.write_text(self.swift.read_text() + "\npublic func dayString(_ value: Int, offset: Int) -> String { \"x\" }\n")
        twin_map = parity_ledger.build_twin_map(self.root)
        rules = {finding.rule for finding in self.findings(twin_map)}
        self.assertIn("duplicate-implementation", rules)
        self.assertEqual(1, self.exit_code(twin_map))

    def test_baseline_suppresses_known_finding_but_rejects_new_finding(self) -> None:
        self.write_clean_tree()
        self.kotlin.write_text(self.kotlin.read_text().replace("SAMPLE_LIMIT = 3", "SAMPLE_LIMIT = 4"))
        twin_map = parity_ledger.build_twin_map(self.root)
        baseline = self.baseline_for(twin_map)
        self.assertEqual(0, self.run_cli(twin_map, baseline)[0])
        self.swift.write_text(self.swift.read_text() + "\nfunc newRegression() {}\n")
        self.assertEqual(1, self.run_cli(twin_map, baseline)[0])

    def test_disappeared_baseline_finding_is_warning_only(self) -> None:
        self.write_clean_tree()
        self.kotlin.write_text(self.kotlin.read_text().replace("SAMPLE_LIMIT = 3", "SAMPLE_LIMIT = 4"))
        twin_map = parity_ledger.build_twin_map(self.root)
        baseline = self.baseline_for(twin_map)
        self.mark_current_tree_as_origin_main()
        self.kotlin.write_text(self.kotlin.read_text().replace("SAMPLE_LIMIT = 4", "SAMPLE_LIMIT = 3"))
        code, output = self.run_cli(twin_map, baseline)
        self.assertEqual(0, code)
        self.assertIn("WARNING debt decreased", output)

    def test_lower_count_with_replacement_finding_still_blocks(self) -> None:
        self.write_clean_tree()
        self.swift.write_text(
            self.swift.read_text().replace(
                "public static let sampleLimit = 3",
                "public static let sampleLimit = 3\n    public static let windowLimit = 5",
            )
        )
        self.kotlin.write_text(
            self.kotlin.read_text().replace(
                "const val SAMPLE_LIMIT = 3",
                "const val SAMPLE_LIMIT = 4\n    const val WINDOW_LIMIT = 6",
            )
        )
        twin_map = parity_ledger.build_twin_map(self.root)
        baseline = self.baseline_for(twin_map)
        self.mark_current_tree_as_origin_main()

        self.swift.write_text(
            self.swift.read_text().replace(
                "public static let windowLimit = 5",
                "public static let windowLimit = 5\n    public static let newLimit = 8",
            )
        )
        self.kotlin.write_text(
            self.kotlin.read_text()
            .replace("const val SAMPLE_LIMIT = 4", "const val SAMPLE_LIMIT = 3")
            .replace("const val WINDOW_LIMIT = 6", "const val WINDOW_LIMIT = 5\n    const val NEW_LIMIT = 9")
        )
        current_map = parity_ledger.build_twin_map(self.root)
        code, output = self.run_cli(current_map, baseline)
        self.assertEqual(1, code)
        self.assertIn("replacement findings are new", output)
        self.assertIn("newLimit", output)

    def test_improvement_base_selection_and_missing_ref_are_fail_closed(self) -> None:
        self.write_clean_tree()
        self.kotlin.write_text(self.kotlin.read_text().replace("SAMPLE_LIMIT = 3", "SAMPLE_LIMIT = 4"))
        twin_map = parity_ledger.build_twin_map(self.root)
        baseline = self.baseline_for(twin_map)
        self.mark_current_tree_as_origin_main()
        base_sha = subprocess.check_output(
            ["git", "rev-parse", "origin/main"], cwd=self.root, text=True
        ).strip()
        self.kotlin.write_text(self.kotlin.read_text().replace("SAMPLE_LIMIT = 4", "SAMPLE_LIMIT = 3"))

        real = parity_ledger.finding_identities_at_git_ref
        with mock.patch.object(parity_ledger, "finding_identities_at_git_ref", wraps=real) as scanned:
            self.assertEqual(0, self.run_cli(twin_map, baseline)[0])
            scanned.assert_called_once_with(self.root, "origin/main")
        with mock.patch.object(parity_ledger, "finding_identities_at_git_ref", wraps=real) as scanned:
            self.assertEqual(0, self.run_cli(twin_map, baseline, base=base_sha)[0])
            scanned.assert_called_once_with(self.root, base_sha)
        code, output = self.run_cli(twin_map, baseline, base="missing/shallow-base")
        self.assertEqual(1, code)
        self.assertIn("cannot scan exact base", output)

    def test_base_ref_is_resolved_once_before_archive(self) -> None:
        self.write_clean_tree()
        self.mark_current_tree_as_origin_main()
        expected = subprocess.check_output(
            ["git", "rev-parse", "origin/main"], cwd=self.root, text=True
        ).strip()
        real = subprocess.check_output
        calls: list[list[str]] = []

        def recording(arguments, **kwargs):
            calls.append(arguments)
            return real(arguments, **kwargs)

        with mock.patch.object(parity_ledger.subprocess, "check_output", side_effect=recording):
            parity_ledger.finding_identities_at_git_ref(self.root, "origin/main")

        self.assertEqual(
            [["git", "rev-parse", "--verify", "origin/main^{commit}"],
             ["git", "archive", "--format=tar", expected]],
            calls,
        )

    def test_counter_increase_beyond_baseline_is_rejected(self) -> None:
        self.write_clean_tree()
        old_map = parity_ledger.build_twin_map(self.root)
        baseline = self.baseline_for(old_map)
        self.swift.write_text(self.swift.read_text() + "\nfunc dayString(_ value: Int) -> String { \"x\" }\n")
        new_map = parity_ledger.build_twin_map(self.root)
        code, output = self.run_cli(new_map, baseline)
        self.assertEqual(1, code)
        self.assertIn("compact baseline drift", output)

    def test_changed_value_of_baselined_mismatch_is_a_new_finding(self) -> None:
        self.write_clean_tree()
        self.kotlin.write_text(self.kotlin.read_text().replace("SAMPLE_LIMIT = 3", "SAMPLE_LIMIT = 4"))
        twin_map = parity_ledger.build_twin_map(self.root)
        baseline = self.baseline_for(twin_map)
        self.kotlin.write_text(self.kotlin.read_text().replace("SAMPLE_LIMIT = 4", "SAMPLE_LIMIT = 5"))
        code, output = self.run_cli(twin_map, baseline)
        self.assertEqual(1, code)
        self.assertIn("constant-value-mismatch", output)


if __name__ == "__main__":
    unittest.main()
