#!/usr/bin/env python3
"""Compact, deterministic, standard-library-only differential harness core."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from pathlib import Path
from typing import Iterable

import parity_shards


class HarnessError(ValueError):
    """Raised when a portable harness contract fails closed."""


_CASE_ID = re.compile(r"[a-z][a-z0-9-]*")
_INPUT_FIELDS = {"args", "caseSha256", "expected", "function", "id", "shard", "suiteVersion"}
_OUTPUT_FIELDS = {"caseSha256", "function", "id", "mutant", "side", "sourceRevision", "suiteVersion", "value"}


def _nonempty_string(value: object, label: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise HarnessError(f"{label} must be a non-empty string")


def _revision(value: object) -> None:
    if not isinstance(value, str) or re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", value) is None:
        raise HarnessError("sourceRevision must be a full lowercase Git revision (40 or 64 hex digits)")


def _reject_constant(token: str) -> None:
    raise HarnessError(f"numbers must be finite, got {token}")


def _object_without_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    value: dict = {}
    for key, item in pairs:
        if key in value:
            raise HarnessError(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


def _validate_portable_json(value: object, path: str = "value") -> None:
    if isinstance(value, str):
        if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
            raise HarnessError(f"{path} strings must contain Unicode scalar values")
        return
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, int):
        if not -(1 << 63) <= value <= (1 << 63) - 1:
            raise HarnessError(f"{path} integer must fit signed 64-bit")
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            raise HarnessError(f"{path} number must be finite")
        return
    if isinstance(value, list):
        for number, item in enumerate(value):
            _validate_portable_json(item, f"{path}[{number}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise HarnessError(f"{path} object keys must be strings")
            _validate_portable_json(key, f"{path} key")
            _validate_portable_json(item, f"{path}.{key}")
        return
    raise HarnessError(f"{path} has non-JSON type {type(value).__name__}")


def parse_json(text: str) -> object:
    try:
        value = json.loads(
            text,
            parse_constant=_reject_constant,
            object_pairs_hook=_object_without_duplicate_keys,
        )
    except json.JSONDecodeError as exc:
        raise HarnessError(f"invalid JSON: {exc}") from exc
    _validate_portable_json(value)
    return value


def canonical_json(value: object) -> str:
    _validate_portable_json(value)
    try:
        return json.dumps(
            value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
        )
    except (TypeError, ValueError) as exc:
        raise HarnessError(f"value is not finite canonical JSON: {exc}") from exc


def _exact_fields(value: object, expected: set[str], path: str) -> dict:
    if not isinstance(value, dict) or set(value) != expected:
        actual = sorted(value) if isinstance(value, dict) else type(value).__name__
        raise HarnessError(f"{path} fields must be exactly {sorted(expected)}, got {actual}")
    return value


def _operation_index() -> dict[str, tuple[parity_shards.ShardSpec, parity_shards.OperationSpec]]:
    parity_shards.validate_registry(parity_shards.REGISTRY)
    return parity_shards.operation_index()


def validate_spec(value: object) -> dict:
    _validate_portable_json(value, "spec")
    spec = _exact_fields(value, {"schemaVersion", "shards", "suiteVersion"}, "spec")
    _nonempty_string(spec["suiteVersion"], "suiteVersion")
    if type(spec["schemaVersion"]) is not int or spec["schemaVersion"] != 1:
        raise HarnessError("spec schemaVersion must be 1")
    if not isinstance(spec["shards"], list):
        raise HarnessError("spec shards must be an array")
    expected_shards = [shard.name for shard in parity_shards.REGISTRY]
    actual_shards: list[str] = []
    operation_index = _operation_index()
    for shard_number, raw_shard in enumerate(spec["shards"]):
        path = f"spec.shards[{shard_number}]"
        shard = _exact_fields(raw_shard, {"name", "operations"}, path)
        if not isinstance(shard["name"], str) or not isinstance(shard["operations"], list):
            raise HarnessError(f"{path} requires string name and operations array")
        actual_shards.append(shard["name"])
        registered = next(
            (item for item in parity_shards.REGISTRY if item.name == shard["name"]), None
        )
        if registered is None:
            raise HarnessError(f"{path} names unknown shard {shard['name']!r}")
        actual_operations: list[str] = []
        for operation_number, raw_operation in enumerate(shard["operations"]):
            op_path = f"{path}.operations[{operation_number}]"
            operation = _exact_fields(raw_operation, {"key", "cases"}, op_path)
            if not isinstance(operation["key"], str) or not isinstance(operation["cases"], list):
                raise HarnessError(f"{op_path} requires string key and cases array")
            actual_operations.append(operation["key"])
            registered_pair = operation_index.get(operation["key"])
            if registered_pair is None or registered_pair[0].name != shard["name"]:
                raise HarnessError(f"{op_path} operation is not registered in shard {shard['name']}")
            if not operation["cases"]:
                raise HarnessError(f"{op_path} must contain at least one case")
            case_ids: list[str] = []
            for case_number, raw_case in enumerate(operation["cases"]):
                case_path = f"{op_path}.cases[{case_number}]"
                case = _exact_fields(raw_case, {"id", "args", "expected"}, case_path)
                if not isinstance(case["id"], str) or _CASE_ID.fullmatch(case["id"]) is None:
                    raise HarnessError(f"{case_path} id must match {_CASE_ID.pattern}")
                if not isinstance(case["args"], dict):
                    raise HarnessError(f"{case_path} args must be an object")
                if tuple(sorted(case["args"])) != registered_pair[1].argument_keys:
                    raise HarnessError(
                        f"{case_path} args must contain exactly {list(registered_pair[1].argument_keys)}"
                    )
                case_ids.append(case["id"])
                try:
                    registered_pair[1].reference(case["args"])
                except parity_shards.RegistryError as exc:
                    raise HarnessError(f"{case_path}: {exc}") from exc
            if len(case_ids) != len(set(case_ids)):
                raise HarnessError(f"{op_path} case ids must be unique")
            if case_ids != sorted(case_ids):
                raise HarnessError(f"{op_path} cases must be in canonical id order")
        expected_operations = [item.key for item in registered.operations]
        if actual_operations != expected_operations:
            raise HarnessError(
                f"{path} operations must exactly match registry order {expected_operations}"
            )
    if actual_shards != expected_shards:
        raise HarnessError(f"spec shards must exactly match registry order {expected_shards}")
    return spec


def load_spec(path: Path) -> dict:
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise HarnessError(f"cannot read case spec {path}: {exc}") from exc
    value = parse_json(raw)
    return validate_spec(value)


def case_digest(row: dict) -> str:
    payload = dict(row)
    payload.pop("caseSha256", None)
    return hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()


def expand_spec(value: object) -> list[dict]:
    spec = validate_spec(value)
    rows: list[dict] = []
    for shard in spec["shards"]:
        for operation in shard["operations"]:
            for case in operation["cases"]:
                row = {
                    "args": case["args"],
                    "expected": case["expected"],
                    "suiteVersion": spec["suiteVersion"],
                    "function": operation["key"],
                    "id": f"{shard['name']}/{operation['key']}/{case['id']}",
                    "shard": shard["name"],
                }
                row["caseSha256"] = case_digest(row)
                rows.append(row)
    return sorted(rows, key=lambda item: item["id"])


def canonical_jsonl(records: Iterable[dict]) -> str:
    rows = list(records)
    if not rows:
        raise HarnessError("JSONL must contain at least one record")
    return "".join(f"{canonical_json(row)}\n" for row in rows)


def parse_jsonl(text: str, label: str) -> list[dict]:
    if not text.endswith("\n"):
        raise HarnessError(f"{label} JSONL requires a final newline")
    lines = text[:-1].split("\n")
    if not lines or any(not line for line in lines):
        raise HarnessError(f"{label} JSONL must be non-empty without blank lines")
    rows: list[dict] = []
    for number, line in enumerate(lines, 1):
        row = parse_json(line)
        if not isinstance(row, dict) or line != canonical_json(row):
            raise HarnessError(f"{label} line {number} is not canonical JSON")
        rows.append(row)
    return rows


def read_jsonl(path: Path, label: str) -> list[dict]:
    try:
        with path.open(encoding="utf-8", newline="") as stream:
            return parse_jsonl(stream.read(), label)
    except (OSError, UnicodeError) as exc:
        raise HarnessError(f"cannot read {label} {path}: {exc}") from exc


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    text = canonical_jsonl(rows)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
    except (OSError, UnicodeError) as exc:
        raise HarnessError(f"cannot write JSONL {path}: {exc}") from exc


def _index(records: Iterable[dict], label: str, fields: set[str]) -> dict[str, dict]:
    indexed: dict[str, dict] = {}
    for number, raw in enumerate(records, 1):
        row = _exact_fields(raw, fields, f"{label}[{number}]")
        case_id = row.get("id")
        if not isinstance(case_id, str) or not case_id:
            raise HarnessError(f"{label}[{number}] requires a non-empty id")
        if case_id in indexed:
            raise HarnessError(f"duplicate {label} id {case_id}")
        indexed[case_id] = row
    if not indexed:
        raise HarnessError(f"{label} must be non-empty")
    return indexed


def _input_index(records: Iterable[dict]) -> dict[str, dict]:
    indexed = _index(records, "input", _INPUT_FIELDS)
    operation_index = _operation_index()
    versions = set()
    for case_id, row in indexed.items():
        _nonempty_string(row["suiteVersion"], "suiteVersion")
        versions.add(row["suiteVersion"])
        if not isinstance(row["function"], str) or not isinstance(row["shard"], str):
            raise HarnessError(f"input id={case_id} function and shard must be strings")
        if not isinstance(row["caseSha256"], str) or not isinstance(row["args"], dict):
            raise HarnessError(f"input id={case_id} requires string caseSha256 and object args")
        prefix = f"{row['shard']}/{row['function']}/"
        if not case_id.startswith(prefix) or _CASE_ID.fullmatch(case_id[len(prefix):]) is None:
            raise HarnessError(f"input id={case_id} is not structurally bound to shard/function")
        pair = operation_index.get(row["function"])
        if pair is None or pair[0].name != row["shard"]:
            raise HarnessError(f"input id={case_id} targets an unknown operation/shard")
        if row["caseSha256"] != case_digest(row):
            raise HarnessError(f"input id={case_id} caseSha256 mismatch")
    if len(versions) != 1:
        raise HarnessError("input suiteVersion must be identical across cases")
    if list(indexed) != sorted(indexed):
        raise HarnessError("input rows must be in canonical id order")
    return indexed


def split_records(records: Iterable[dict]) -> dict[str, list[dict]]:
    indexed = _input_index(records)
    shards = {shard.name: [] for shard in parity_shards.REGISTRY}
    for row in indexed.values():
        shards[row["shard"]].append(row)
    empty = [name for name, rows in shards.items() if not rows]
    if empty:
        raise HarnessError(f"every registered shard must be non-empty: {empty}")
    return shards


def merge_records(parts: Iterable[Iterable[dict]], expected: Iterable[dict]) -> list[dict]:
    expected_index = _input_index(expected)
    merged: list[dict] = []
    seen: set[str] = set()
    part_shards: list[set[str]] = []
    for part in parts:
        part = list(part)
        part_shards.append({row.get("shard") for row in part if isinstance(row, dict) and isinstance(row.get("shard"), str)})
        for row in part:
            case_id = row.get("id") if isinstance(row, dict) else None
            if case_id in seen:
                raise HarnessError(f"duplicate shard id {case_id}")
            if isinstance(case_id, str):
                seen.add(case_id)
            merged.append(row)
    actual_index = _input_index(merged)
    missing = sorted(set(expected_index) - set(actual_index))
    unexpected = sorted(set(actual_index) - set(expected_index))
    if missing or unexpected:
        raise HarnessError(f"shard IDs mismatch: missing={missing} unexpected={unexpected}")
    registered_shards = [{shard.name} for shard in parity_shards.REGISTRY]
    if part_shards != registered_shards:
        raise HarnessError("merge requires one part per registered shard in registry order")
    for case_id in expected_index:
        if canonical_json(actual_index[case_id]) != canonical_json(expected_index[case_id]):
            raise HarnessError(f"shard id={case_id} content mismatch")
    return [actual_index[case_id] for case_id in sorted(actual_index)]


def run_records(records: Iterable[dict], side: str, *, source_revision: str, mutant: bool = False) -> list[dict]:
    _revision(source_revision)
    if side not in {"core", "reference"}:
        raise HarnessError("side must be core or reference")
    indexed = _input_index(records)
    operations = _operation_index()
    output: list[dict] = []
    for case_id, row in indexed.items():
        operation = operations[row["function"]][1]
        try:
            value = (operation.core if side == "core" else operation.reference)(row["args"])
            if mutant:
                value = operation.mutant(value)
        except parity_shards.RegistryError as exc:
            raise HarnessError(f"{side} id={case_id}: {exc}") from exc
        canonical_json(value)
        output.append(
            {
                "caseSha256": row["caseSha256"],
                "function": row["function"],
                "id": case_id,
                "mutant": mutant,
                "side": side,
                "sourceRevision": source_revision,
                "suiteVersion": row["suiteVersion"],
                "value": value,
            }
        )
    return output


def _output_index(records: Iterable[dict], label: str) -> dict[str, dict]:
    indexed = _index(records, label, _OUTPUT_FIELDS)
    for case_id, row in indexed.items():
        if not isinstance(row["caseSha256"], str) or not isinstance(row["function"], str):
            raise HarnessError(f"{label} id={case_id} function and caseSha256 must be strings")
        if not isinstance(row["side"], str) or type(row["mutant"]) is not bool:
            raise HarnessError(f"{label} id={case_id} requires string side and boolean mutant")
        canonical_json(row["value"])
    if list(indexed) != sorted(indexed):
        raise HarnessError(f"{label} rows must be in canonical id order")
    return indexed


def _bound_output(inputs: dict[str, dict], records: Iterable[dict], side: str,
                  expected_revision: str, *, allow_mutants: bool = False) -> dict[str, dict]:
    _revision(expected_revision)
    _nonempty_string(side, "side")
    actual = _output_index(records, f"{side} output")
    missing = sorted(set(inputs) - set(actual))
    unexpected = sorted(set(actual) - set(inputs))
    if missing or unexpected:
        raise HarnessError(f"{side} IDs mismatch: missing={missing} unexpected={unexpected}")
    for case_id, row in actual.items():
        if row["side"] != side:
            raise HarnessError(f"{side} id={case_id} side mismatch")
        if row["sourceRevision"] != expected_revision:
            raise HarnessError(f"{side} id={case_id} sourceRevision mismatch")
        if row["mutant"] and not allow_mutants:
            raise HarnessError(f"{side} id={case_id} mutant output is forbidden in positive compare/validate")
        for field in ("caseSha256", "function", "suiteVersion"):
            if row[field] != inputs[case_id][field]:
                raise HarnessError(f"{side} id={case_id} {field} mismatch")
    return actual


def _oracle_diffs(inputs: dict[str, dict], output: dict[str, dict], side: str) -> list[str]:
    return [
        f"EXPECTED id={case_id} side={side} expected={canonical_json(source['expected'])} "
        f"actual={canonical_json(output[case_id]['value'])}"
        for case_id, source in inputs.items()
        if canonical_json(source["expected"]) != canonical_json(output[case_id]["value"])
    ]


def validate_records(inputs: Iterable[dict], output: Iterable[dict], side: str,
                     *, expected_revision: str) -> list[str]:
    """Check one artifact against literal oracles, without a peer build or output."""
    expected = _input_index(inputs)
    actual = _bound_output(expected, output, side, expected_revision)
    return _oracle_diffs(expected, actual, side)


def compare_records(inputs: Iterable[dict], core: Iterable[dict], reference: Iterable[dict],
                    *, expected_revision: str, core_side: str = "core",
                    reference_side: str = "reference") -> list[str]:
    """Check both oracles and parity against the caller's intended immutable revision."""
    if core_side == reference_side:
        raise HarnessError("comparison requires distinct sides")
    expected = _input_index(inputs)
    left = _bound_output(expected, core, core_side, expected_revision)
    right = _bound_output(expected, reference, reference_side, expected_revision)
    diffs = _oracle_diffs(expected, left, core_side) + _oracle_diffs(expected, right, reference_side)
    for case_id in expected:
        if canonical_json(left[case_id]["value"]) != canonical_json(right[case_id]["value"]):
            diffs.append(f"DIFF id={case_id} function={expected[case_id]['function']} "
                         f"{core_side}={canonical_json(left[case_id]['value'])} "
                         f"{reference_side}={canonical_json(right[case_id]['value'])}")
    return diffs


def verify_mutant(
    inputs: Iterable[dict], core: Iterable[dict], reference: Iterable[dict], expected_side: str,
    *, expected_revision: str
) -> int:
    if expected_side not in {"core", "reference"}:
        raise HarnessError("expected mutant side must be core or reference")
    input_rows = list(inputs)
    core_rows = list(core)
    reference_rows = list(reference)
    side_rows = {"core": core_rows, "reference": reference_rows}
    other_side = "reference" if expected_side == "core" else "core"
    expected_inputs = _input_index(input_rows)
    for side, rows in side_rows.items():
        _bound_output(expected_inputs, rows, side, expected_revision, allow_mutants=True)
    if (
        not side_rows[expected_side]
        or not all(row["mutant"] is True for row in side_rows[expected_side])
        or any(row["mutant"] is not False for row in side_rows[other_side])
    ):
        raise HarnessError(f"expected {expected_side} mutant metadata on exactly one side")
    normal = _output_index(side_rows[other_side], "normal output")
    if _oracle_diffs(expected_inputs, normal, other_side):
        raise HarnessError("non-mutant side must match expected results")
    mutated = _output_index(side_rows[expected_side], "mutant output")
    killed = {case_id for case_id in expected_inputs
              if canonical_json(mutated[case_id]["value"]) != canonical_json(normal[case_id]["value"])}
    expected = {row["id"] for row in input_rows}
    if killed != expected:
        raise HarnessError(
            f"{expected_side} mutant was not killed exactly: missing={sorted(expected-killed)} "
            f"unexpected={sorted(killed-expected)}"
        )
    return len(killed)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    expand = commands.add_parser("expand")
    expand.add_argument("spec", type=Path)
    expand.add_argument("output", type=Path)
    split = commands.add_parser("split")
    split.add_argument("input", type=Path)
    split.add_argument("output_dir", type=Path)
    run = commands.add_parser("run")
    run.add_argument("side", choices=("core", "reference"))
    run.add_argument("input", type=Path)
    run.add_argument("output", type=Path)
    run.add_argument("--source-revision", required=True)
    run.add_argument("--mutant", action="store_true")
    merge = commands.add_parser("merge")
    merge.add_argument("expected", type=Path)
    merge.add_argument("output", type=Path)
    merge.add_argument("parts", type=Path, nargs="+")
    compare = commands.add_parser("compare")
    compare.add_argument("input", type=Path)
    compare.add_argument("core", type=Path)
    compare.add_argument("reference", type=Path)
    compare.add_argument("--core-side", default="core")
    compare.add_argument("--reference-side", default="reference")
    validate = commands.add_parser("validate")
    validate.add_argument("side")
    validate.add_argument("input", type=Path)
    validate.add_argument("output", type=Path)
    verify = commands.add_parser("verify-mutant")
    verify.add_argument("side", choices=("core", "reference"))
    verify.add_argument("input", type=Path)
    verify.add_argument("core", type=Path)
    verify.add_argument("reference", type=Path)
    for command in (compare, validate, verify):
        command.add_argument("--expected-revision", required=True)
    args = parser.parse_args(argv)

    if args.command == "expand":
        write_jsonl(args.output, expand_spec(load_spec(args.spec)))
    elif args.command == "split":
        shards = split_records(read_jsonl(args.input, "input"))
        unexpected = sorted(path.name for path in args.output_dir.glob("*.jsonl")
                            if path.name not in {f"{name}.jsonl" for name in shards})
        if unexpected:
            raise HarnessError(f"split output directory contains unexpected JSONL: {unexpected}")
        for name, rows in shards.items():
            write_jsonl(args.output_dir / f"{name}.jsonl", rows)
    elif args.command == "run":
        write_jsonl(
            args.output,
            run_records(read_jsonl(args.input, "input"), args.side, source_revision=args.source_revision, mutant=args.mutant),
        )
    elif args.command == "merge":
        expected = read_jsonl(args.expected, "expected input")
        parts = [read_jsonl(path, f"shard {path}") for path in args.parts]
        write_jsonl(args.output, merge_records(parts, expected))
    elif args.command == "validate":
        diffs = validate_records(read_jsonl(args.input, "input"),
                                 read_jsonl(args.output, "output"), args.side,
                                 expected_revision=args.expected_revision)
        for line in diffs:
            print(line)
        return 1 if diffs else 0
    elif args.command == "compare":
        diffs = compare_records(
            read_jsonl(args.input, "input"),
            read_jsonl(args.core, "core output"),
            read_jsonl(args.reference, "reference output"),
            expected_revision=args.expected_revision,
            core_side=args.core_side, reference_side=args.reference_side,
        )
        for line in diffs:
            print(line)
        return 1 if diffs else 0
    else:
        killed = verify_mutant(
            read_jsonl(args.input, "input"),
            read_jsonl(args.core, "core output"),
            read_jsonl(args.reference, "reference output"),
            args.side,
            expected_revision=args.expected_revision,
        )
        print(f"OK killed {killed} {args.side} mutant case(s)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
