from __future__ import annotations

import io
import json
import sys
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

import parity_harness
import parity_shards


FIXTURE = TOOLS / "parity_case_specs/core_reference.json"


def invoke_cli(args):
    if args[0] == "run":
        args += ["--source-revision", "a" * 40]
    elif args[0] in ("compare", "verify-mutant", "validate"):
        args += ["--expected-revision", "a" * 40]
    return parity_harness.main(args)


def valid_spec() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


class SharedOracleTests(unittest.TestCase):
    REVISION = "a" * 40

    def setUp(self):
        self.rows = parity_harness.expand_spec(valid_spec())

    def run_side(self, side="core"):
        return parity_harness.run_records(self.rows, side, source_revision=self.REVISION)

    def test_one_platform_validates_without_peer(self):
        output = self.run_side()
        for row in output:
            row["side"] = "android"
        self.assertEqual([], parity_harness.validate_records(
            self.rows, output, "android", expected_revision=self.REVISION))

    def test_agreeing_but_wrong_outputs_fail_oracle(self):
        core, reference = self.run_side(), self.run_side("reference")
        core[0]["value"] = reference[0]["value"] = 999
        errors = parity_harness.compare_records(
            self.rows, core, reference, expected_revision=self.REVISION)
        self.assertEqual(2, len(errors))
        self.assertTrue(all("EXPECTED" in error for error in errors))

    def test_revision_rejects_stale_and_missing_contract(self):
        output = self.run_side()
        for revision in ("", "main", "a" * 7, "g" * 40, "b" * 40):
            with self.subTest(revision=revision), self.assertRaises(parity_harness.HarnessError):
                parity_harness.validate_records(
                    self.rows, output, "core", expected_revision=revision)
        output[0]["sourceRevision"] = "b" * 40
        with self.assertRaisesRegex(parity_harness.HarnessError, "sourceRevision"):
            parity_harness.validate_records(
                self.rows, output, "core", expected_revision=self.REVISION)

    def test_expected_and_suite_version_are_digest_bound(self):
        for field, value in (("expected", 999), ("suiteVersion", "changed")):
            rows = [dict(row) for row in self.rows]
            rows[0][field] = value
            with self.subTest(field=field), self.assertRaises(parity_harness.HarnessError):
                parity_harness.validate_records(
                    rows, self.run_side(), "core", expected_revision=self.REVISION)

    def test_suite_version_required_and_nonempty(self):
        for value in (None, "", "   ", 1):
            spec = valid_spec()
            spec["suiteVersion"] = value
            with self.subTest(value=value), self.assertRaises(parity_harness.HarnessError):
                parity_harness.expand_spec(spec)

    def test_missing_expected_is_rejected(self):
        spec = valid_spec()
        del spec["shards"][0]["operations"][0]["cases"][0]["expected"]
        with self.assertRaisesRegex(parity_harness.HarnessError, "fields must be exactly"):
            parity_harness.expand_spec(spec)

    def test_stale_or_mixed_provenance_is_rejected_even_when_values_agree(self):
        for side in ("core", "reference", "both"):
            core, reference = self.run_side(), self.run_side("reference")
            for row in (core if side == "core" else reference if side == "reference" else core + reference):
                row["sourceRevision"] = "b" * 40
            with self.subTest(side=side), self.assertRaisesRegex(parity_harness.HarnessError, "sourceRevision"):
                parity_harness.compare_records(self.rows, core, reference, expected_revision=self.REVISION)
        output = self.run_side()
        output[0]["suiteVersion"] = "stale"
        with self.assertRaisesRegex(parity_harness.HarnessError, "suiteVersion"):
            parity_harness.validate_records(self.rows, output, "core", expected_revision=self.REVISION)

    def test_rehashed_case_changes_still_reject_previous_output(self):
        output = self.run_side()
        for field, value in (("expected", 999), ("suiteVersion", "new-version")):
            rows = [{**row, field: value} for row in self.rows]
            for row in rows:
                row["caseSha256"] = parity_harness.case_digest(row)
            with self.subTest(field=field), self.assertRaisesRegex(parity_harness.HarnessError, "caseSha256"):
                parity_harness.validate_records(rows, output, "core", expected_revision=self.REVISION)

    def test_validation_rejects_invalid_single_artifact_and_preserves_exact_oracle_types(self):
        output = self.run_side()
        for candidate in (output[:-1], [*output, output[0]],
                          [{**output[0], "side": "swift"}, *output[1:]],
                          [{**output[0], "mutant": True}, *output[1:]]):
            with self.subTest(candidate=candidate), self.assertRaises(parity_harness.HarnessError):
                parity_harness.validate_records(self.rows, candidate, "core", expected_revision=self.REVISION)
        for expected, actual in ((True, 1), ([1], [1.0]), ({"x": -0.0}, {"x": 0.0})):
            rows = [dict(row) for row in self.rows]
            rows[0]["expected"] = expected
            rows[0]["caseSha256"] = parity_harness.case_digest(rows[0])
            candidate = [dict(row) for row in output]
            candidate[0].update(caseSha256=rows[0]["caseSha256"], value=actual)
            with self.subTest(expected=expected):
                self.assertEqual(1, len(parity_harness.validate_records(
                    rows, candidate, "core", expected_revision=self.REVISION)))

    def test_mutant_control_rejects_wrong_normal_side(self):
        core = parity_harness.run_records(self.rows, "core", source_revision=self.REVISION, mutant=True)
        reference = self.run_side("reference")
        reference[0]["value"] = 999
        with self.assertRaisesRegex(parity_harness.HarnessError, "non-mutant side"):
            parity_harness.verify_mutant(self.rows, core, reference, "core", expected_revision=self.REVISION)

    def test_single_side_cli_exit_codes_and_later_artifact_comparison(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            inputs, android, swift = (target / name for name in ("cases.jsonl", "android.jsonl", "swift.jsonl"))
            parity_harness.write_jsonl(inputs, self.rows)
            output = self.run_side()
            for row in output:
                row["side"] = "android"
            parity_harness.write_jsonl(android, output)
            command = [sys.executable, str(TOOLS / "parity_harness.py"), "validate", "android", str(inputs), str(android)]
            def check(args, code, message=""):
                result = subprocess.run(args, capture_output=True, text=True)
                self.assertEqual(code, result.returncode, result.stdout + result.stderr)
                self.assertIn(message, result.stdout + result.stderr)
            check(command, 2, "--expected-revision")
            check(command + ["--expected-revision", "main"], 2, "full lowercase Git revision")
            command += ["--expected-revision", self.REVISION]
            check(command, 0)
            self.assertFalse(swift.exists())  # No peer artifact is needed for standalone success.
            output[0]["value"] = 999
            parity_harness.write_jsonl(android, output)
            check(command, 1, "EXPECTED")
            for row in output:
                row["side"] = "swift"
            parity_harness.write_jsonl(swift, output)
            check([sys.executable, str(TOOLS / "parity_harness.py"), "compare", str(inputs), str(android), str(swift),
                   "--core-side", "android", "--reference-side", "swift", "--expected-revision", self.REVISION], 1, "EXPECTED")
            output[0]["sourceRevision"] = "b" * 40
            parity_harness.write_jsonl(swift, output)
            check([sys.executable, str(TOOLS / "parity_harness.py"), "validate", "swift", str(inputs), str(swift),
                   "--expected-revision", self.REVISION], 2, "sourceRevision")

    def test_oracle_is_literal_and_not_reference_generated(self):
        spec = valid_spec()
        spec["shards"][0]["operations"][0]["cases"][0]["expected"] = 999
        rows = parity_harness.expand_spec(spec)
        output = parity_harness.run_records(rows, "reference", source_revision=self.REVISION)
        self.assertEqual(1, len(parity_harness.validate_records(
            rows, output, "reference", expected_revision=self.REVISION)))


class CaseSchemaTests(unittest.TestCase):
    def test_checked_fixture_expands_deterministically_and_canonically(self) -> None:
        spec = parity_harness.load_spec(FIXTURE)
        first = parity_harness.expand_spec(spec)
        second = parity_harness.expand_spec(parity_harness.load_spec(FIXTURE))
        self.assertEqual(first, second)
        self.assertEqual(parity_harness.canonical_jsonl(first), parity_harness.canonical_jsonl(second))
        self.assertEqual(sorted(row["id"] for row in first), [row["id"] for row in first])
        for row in first:
            self.assertEqual(
                {"args", "caseSha256", "expected", "function", "id", "shard", "suiteVersion"}, set(row)
            )
            self.assertEqual(row["caseSha256"], parity_harness.case_digest(row))

    def test_schema_rejects_unknown_fields_at_every_level(self) -> None:
        paths = [
            (),
            ("shards", 0),
            ("shards", 0, "operations", 0),
            ("shards", 0, "operations", 0, "cases", 0),
        ]
        for path in paths:
            candidate = valid_spec()
            node = candidate
            for part in path:
                node = node[part]
            node["unknown"] = True
            with self.subTest(path=path), self.assertRaisesRegex(
                parity_harness.HarnessError, "fields must be exactly"
            ):
                parity_harness.validate_spec(candidate)

    def test_schema_rejects_version_order_duplicates_and_nonfinite_values(self) -> None:
        candidate = valid_spec()
        candidate["schemaVersion"] = 2
        with self.assertRaisesRegex(parity_harness.HarnessError, "schemaVersion"):
            parity_harness.validate_spec(candidate)

        candidate = valid_spec()
        candidate["shards"][0]["operations"][0]["cases"].reverse()
        with self.assertRaisesRegex(parity_harness.HarnessError, "canonical id order"):
            parity_harness.validate_spec(candidate)

        candidate = valid_spec()
        candidate["shards"][0]["operations"][0]["cases"][1]["id"] = "above"
        with self.assertRaisesRegex(parity_harness.HarnessError, "unique"):
            parity_harness.validate_spec(candidate)

        with self.assertRaisesRegex(parity_harness.HarnessError, "finite"):
            parity_harness.parse_json('{"schemaVersion":NaN,"shards":[]}')

        with self.assertRaisesRegex(parity_harness.HarnessError, "duplicate JSON key"):
            parity_harness.parse_json('{"schemaVersion":1,"schemaVersion":1,"shards":[]}')

        candidate = valid_spec()
        candidate["shards"][0]["operations"][0]["cases"][0]["args"]["value"] = 1 << 80
        with self.assertRaisesRegex(parity_harness.HarnessError, "signed 64-bit"):
            parity_harness.validate_spec(candidate)

    def test_jsonl_requires_exact_canonical_encoding(self) -> None:
        rows = parity_harness.expand_spec(valid_spec())
        encoded = parity_harness.canonical_jsonl(rows)
        self.assertEqual(rows, parity_harness.parse_jsonl(encoded, "fixture"))
        with self.assertRaisesRegex(parity_harness.HarnessError, "canonical"):
            parity_harness.parse_jsonl(encoded.replace(":", ": ", 1), "fixture")
        with self.assertRaisesRegex(parity_harness.HarnessError, "final newline"):
            parity_harness.parse_jsonl(encoded.rstrip("\n"), "fixture")


class RegistryAndShardTests(unittest.TestCase):
    def test_registry_is_ordered_unique_and_is_the_operation_authority(self) -> None:
        parity_shards.validate_registry(parity_shards.REGISTRY)
        operation_keys = [
            operation.key for shard in parity_shards.REGISTRY for operation in shard.operations
        ]
        self.assertEqual(len(operation_keys), len(set(operation_keys)))
        self.assertEqual(operation_keys, sorted(operation_keys))

        duplicate = (
            parity_shards.ShardSpec(
                "a", (parity_shards.REGISTRY[0].operations[0],)
            ),
            parity_shards.ShardSpec(
                "b", (parity_shards.REGISTRY[0].operations[0],)
            ),
        )
        with self.assertRaisesRegex(parity_shards.RegistryError, "duplicate operation"):
            parity_shards.validate_registry(duplicate)

    def test_split_is_disjoint_complete_nonempty_canonical_and_exact_remerge(self) -> None:
        rows = parity_harness.expand_spec(valid_spec())
        shards = parity_harness.split_records(rows)
        self.assertEqual([shard.name for shard in parity_shards.REGISTRY], list(shards))
        id_sets = [{row["id"] for row in part} for part in shards.values()]
        self.assertTrue(all(id_set for id_set in id_sets))
        self.assertFalse(any(left & right for i, left in enumerate(id_sets) for right in id_sets[i + 1 :]))
        self.assertEqual({row["id"] for row in rows}, set().union(*id_sets))
        self.assertEqual(rows, parity_harness.merge_records(list(shards.values()), rows))
        self.assertEqual(
            parity_harness.canonical_jsonl(rows),
            parity_harness.canonical_jsonl(parity_harness.merge_records(list(shards.values()), rows)),
        )

    def test_merge_rejects_missing_duplicate_and_unexpected_ids(self) -> None:
        rows = parity_harness.expand_spec(valid_spec())
        for parts, message in (
            ([[*rows, rows[0]]], "duplicate"),
            ([rows[:-1]], "missing"),
            ([[*rows, {**rows[-1], "id": "unexpected"}]], "unexpected"),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(
                parity_harness.HarnessError, message
            ):
                parity_harness.merge_records(parts, rows)

    def test_merge_rejects_reordered_shard_rows(self) -> None:
        rows = parity_harness.expand_spec(valid_spec())
        with self.assertRaisesRegex(parity_harness.HarnessError, "canonical id order"):
            parity_harness.merge_records([list(reversed(rows))], rows)

    def test_merge_binds_exactly_one_part_to_each_registered_shard(self) -> None:
        rows = parity_harness.expand_spec(valid_spec())
        with self.assertRaisesRegex(parity_harness.HarnessError, "one part per registered shard"):
            parity_harness.merge_records([[rows[0]], rows[1:]], rows)

    def test_split_rejects_stale_jsonl_in_output_directory(self) -> None:
        rows = parity_harness.expand_spec(valid_spec())
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            source = target / "cases.jsonl"
            output = target / "shards"
            parity_harness.write_jsonl(source, rows)
            output.mkdir()
            (output / "stale.jsonl").write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(parity_harness.HarnessError, "unexpected JSONL"):
                invoke_cli(["split", str(source), str(output)])


class ComparatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.rows = parity_harness.expand_spec(valid_spec())

    def test_positive_core_reference_compare(self) -> None:
        core = parity_harness.run_records(self.rows, "core", source_revision="a" * 40)
        reference = parity_harness.run_records(self.rows, "reference", source_revision="a" * 40)
        self.assertEqual([], parity_harness.compare_records(self.rows, core, reference, expected_revision="a" * 40))

    def test_both_mutant_sides_are_killed(self) -> None:
        normal_core = parity_harness.run_records(self.rows, "core", source_revision="a" * 40)
        normal_reference = parity_harness.run_records(self.rows, "reference", source_revision="a" * 40)
        core_mutant = parity_harness.run_records(self.rows, "core", mutant=True, source_revision="a" * 40)
        reference_mutant = parity_harness.run_records(self.rows, "reference", mutant=True, source_revision="a" * 40)
        self.assertEqual(
            len(self.rows),
            parity_harness.verify_mutant(self.rows, core_mutant, normal_reference, "core", expected_revision="a" * 40),
        )
        self.assertEqual(
            len(self.rows),
            parity_harness.verify_mutant(self.rows, normal_core, reference_mutant, "reference", expected_revision="a" * 40),
        )
        with self.assertRaisesRegex(parity_harness.HarnessError, "expected core mutant"):
            parity_harness.verify_mutant(
                self.rows, normal_core, reference_mutant, "core",
                expected_revision="a" * 40,
            )

    def test_output_contract_rejects_missing_duplicate_unexpected_and_retargeted_rows(self) -> None:
        core = parity_harness.run_records(self.rows, "core", source_revision="a" * 40)
        reference = parity_harness.run_records(self.rows, "reference", source_revision="a" * 40)
        mutations = [
            (core[:-1], "missing"),
            ([*core, core[0]], "duplicate"),
            ([*core, {**core[-1], "id": "unexpected"}], "unexpected"),
            ([{**core[0], "function": "Other.operation/0"}, *core[1:]], "function mismatch"),
            ([{**core[0], "extra": True}, *core[1:]], "fields must be exactly"),
        ]
        for mutated, message in mutations:
            with self.subTest(message=message), self.assertRaisesRegex(
                parity_harness.HarnessError, message
            ):
                parity_harness.compare_records(self.rows, mutated, reference, expected_revision="a" * 40)

    def test_malformed_metadata_always_raises_stable_harness_error(self) -> None:
        core = parity_harness.run_records(self.rows, "core", source_revision="a" * 40)
        reference = parity_harness.run_records(self.rows, "reference", source_revision="a" * 40)
        malformed_input = [{**self.rows[0], "function": []}, *self.rows[1:]]
        with self.assertRaises(parity_harness.HarnessError):
            parity_harness.compare_records(malformed_input, core, reference, expected_revision="a" * 40)
        with self.assertRaises(parity_harness.HarnessError):
            parity_harness.verify_mutant(self.rows, [42], reference, "core", expected_revision="a" * 40)

    def test_output_order_and_full_case_identity_are_canonical_and_bound(self) -> None:
        core = parity_harness.run_records(self.rows, "core", source_revision="a" * 40)
        reference = parity_harness.run_records(self.rows, "reference", source_revision="a" * 40)
        with self.assertRaisesRegex(parity_harness.HarnessError, "canonical id order"):
            parity_harness.compare_records(self.rows, list(reversed(core)), reference, expected_revision="a" * 40)

        rebound = [dict(row) for row in self.rows]
        rebound[0]["id"] = "other/Portable.clamp/3/above"
        rebound[0]["caseSha256"] = parity_harness.case_digest(rebound[0])
        rebound.sort(key=lambda row: row["id"])
        with self.assertRaisesRegex(parity_harness.HarnessError, "structurally bound"):
            parity_harness.run_records(rebound, "core", source_revision="a" * 40)

    def test_one_reference_shard_end_to_end_and_cli(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            expanded = target / "cases.jsonl"
            core = target / "core.jsonl"
            reference = target / "reference.jsonl"
            core_mutant = target / "core-mutant.jsonl"
            reference_mutant = target / "reference-mutant.jsonl"
            with redirect_stdout(io.StringIO()):
                self.assertEqual(0, invoke_cli(["expand", str(FIXTURE), str(expanded)]))
                self.assertEqual(0, invoke_cli(["run", "core", str(expanded), str(core)]))
                self.assertEqual(0, invoke_cli(["run", "reference", str(expanded), str(reference)]))
                self.assertEqual(
                    0,
                    invoke_cli(
                        ["compare", str(expanded), str(core), str(reference)]
                    ),
                )
                self.assertEqual(
                    0,
                    invoke_cli(
                        ["run", "core", str(expanded), str(core_mutant), "--mutant"]
                    ),
                )
                self.assertEqual(
                    0,
                    invoke_cli(
                        ["run", "reference", str(expanded), str(reference_mutant), "--mutant"]
                    ),
                )
                self.assertEqual(
                    0,
                    invoke_cli(
                        [
                            "verify-mutant", "core", str(expanded),
                            str(core_mutant), str(reference),
                        ]
                    ),
                )
                self.assertEqual(
                    0,
                    invoke_cli(
                        [
                            "verify-mutant", "reference", str(expanded),
                            str(core), str(reference_mutant),
                        ]
                    ),
                )
            self.assertEqual(self.rows, parity_harness.read_jsonl(expanded, "expanded"))


class PortableContractRegressionTests(unittest.TestCase):
    def test_schema_version_requires_integer_one(self):
        for version in (True, 1.0):
            spec = valid_spec()
            spec["schemaVersion"] = version
            with self.subTest(version=version), self.assertRaises(parity_harness.HarnessError):
                parity_harness.validate_spec(spec)

    def test_comparison_preserves_nested_types_and_signed_zero(self):
        rows = parity_harness.expand_spec(valid_spec())
        for left, right in (({"x": True}, {"x": 1}), ([1], [1.0]), (-0.0, 0.0)):
            core = parity_harness.run_records(rows, "core", source_revision="a" * 40)
            reference = parity_harness.run_records(rows, "reference", source_revision="a" * 40)
            core[0]["value"], reference[0]["value"] = left, right
            with self.subTest(left=left, right=right):
                self.assertTrue(any(line.startswith("DIFF") for line in parity_harness.compare_records(rows, core, reference, expected_revision="a" * 40)))

    def test_unicode_separators_round_trip(self):
        rows = [{"value": "a\u0085b\u2028c\u2029d"}]
        self.assertEqual(rows, parity_harness.parse_jsonl(parity_harness.canonical_jsonl(rows), "unicode"))

    def test_crlf_is_rejected_in_memory_and_on_disk(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.jsonl"
            path.write_bytes(b'{"value":1}\r\n')
            with self.assertRaises(parity_harness.HarnessError):
                parity_harness.parse_jsonl(path.read_bytes().decode(), "input")
            with self.assertRaises(parity_harness.HarnessError):
                parity_harness.read_jsonl(path, "input")

    def test_unpaired_surrogates_are_rejected(self):
        for value in ("\ud800", {"\udfff": 1}):
            with self.subTest(value=repr(value)), self.assertRaises(parity_harness.HarnessError):
                parity_harness.canonical_json(value)

    def test_clamp_preserves_value_at_mixed_numeric_boundaries(self):
        operation = parity_shards.REGISTRY[0].operations[0]
        for value in (0.0, -0.0, 10.0):
            args = {"lower": 0, "upper": 10, "value": value}
            with self.subTest(value=value):
                self.assertEqual(parity_harness.canonical_json(value), parity_harness.canonical_json(operation.core(args)))
                self.assertEqual(parity_harness.canonical_json(value), parity_harness.canonical_json(operation.reference(args)))

    def test_write_failure_reports_harness_error(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(parity_harness.HarnessError):
                parity_harness.write_jsonl(Path(directory), [{"value": 1}])


if __name__ == "__main__":
    unittest.main()
