#!/usr/bin/env python3
"""Inventory and gate declared Swift/Kotlin parity contracts.

The ledger is deliberately lexical. It does not compile either language and uses only
the Python standard library. Compact checked metadata hashes exact semantic sets and
accepted finding identities; normal runs independently rederive both from source.

Usage:
  python3 Tools/parity_ledger.py
  python3 Tools/parity_ledger.py --no-baseline
  python3 Tools/parity_ledger.py --bootstrap-map --write-baseline

New semantic debt is governed by exact, manually reviewed typed dispositions.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Iterable

import issue_ref


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MAP = ROOT / "Tools/parity_twin_map.json"
DEFAULT_BASELINE = ROOT / "Tools/parity_ledger_baseline.json"

SWIFT_GLOBS = (
    "Packages/StrandAnalytics/Sources/**/*.swift",
    "Packages/StrandImport/Sources/**/*.swift",
    "Packages/WhoopStore/Sources/**/*.swift",
    "Packages/WhoopProtocol/Sources/**/*.swift",
    "Packages/OuraProtocol/Sources/**/*.swift",
)
KOTLIN_GLOBS = (
    "android/app/src/main/java/com/noop/analytics/**/*.kt",
    "android/app/src/main/java/com/noop/ingest/**/*.kt",
    "android/app/src/main/java/com/noop/data/**/*.kt",
    "android/app/src/main/java/com/noop/protocol/**/*.kt",
    "android/app/src/main/java/com/noop/oura/**/*.kt",
)
SWIFT_EXCLUDED_GLOBS = (
    "Packages/NoopLocalAccess/Sources/**/*.swift",
    "Packages/PolarProtocol/Sources/**/*.swift",
    "Packages/StrandDesign/Sources/**/*.swift",
    "Strand/**/*.swift",
    "StrandiOS*/**/*.swift",
    "NOOPWatch*/**/*.swift",
)
KOTLIN_EXCLUDED_GLOBS = (
    "android/app/src/main/java/com/noop/*.kt",
    "android/app/src/main/java/com/noop/ai/**/*.kt",
    "android/app/src/main/java/com/noop/alarm/**/*.kt",
    "android/app/src/main/java/com/noop/ble/**/*.kt",
    "android/app/src/main/java/com/noop/location/**/*.kt",
    "android/app/src/main/java/com/noop/notif/**/*.kt",
    "android/app/src/main/java/com/noop/polar/**/*.kt",
    "android/app/src/main/java/com/noop/testcentre/**/*.kt",
    "android/app/src/main/java/com/noop/ui/**/*.kt",
    "android/app/src/main/java/com/noop/update/**/*.kt",
    "android/app/src/main/java/com/noop/widget/**/*.kt",
)
PRODUCTION_GLOBS = (
    "Packages/**/Sources/**/*.swift",
    "Strand/**/*.swift",
    "StrandiOS*/**/*.swift",
    "NOOPWatch*/**/*.swift",
    "android/app/src/main/java/**/*.kt",
)
TEST_GLOBS = (
    "Packages/**/Tests/**/*.swift",
    "StrandTests/**/*.swift",
    "android/app/src/test/**/*.kt",
    "android/app/src/androidTest/**/*.kt",
)
REFERENCE_GLOBS = (
    "Packages/**/*.swift",
    "Strand/**/*.swift",
    "StrandTests/**/*.swift",
    "StrandiOS*/**/*.swift",
    "NOOPWatch*/**/*.swift",
    "android/**/*.kt",
)

# These constants intentionally describe different platform-local persistence schemas. Their normalized
# names happen to match, but their migration generations do not and must not be compared as parity twins.
# Keep the exclusion exact so unrelated schema constants still go through the normal pairing audit.
CONSTANT_NON_TWIN_PAIRS = frozenset({
    (
        "Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift::schemaVersion",
        "android/app/src/main/java/com/noop/data/WhoopDatabase.kt::SCHEMA_VERSION",
    ),
})

HARD_FINDING_RULES = frozenset({
    "malformed-twin-map", "duplicate-twin-target", "twin-map-overlap",
    "stale-twin-file", "stale-twin-function", "stale-twin-property",
    "unmapped-declared-function-pair", "stale-declared-function-pair",
    "unmapped-declared-file-pair", "stale-declared-file-pair",
    "unmapped-constant-pair", "stale-constant-pair", "dead-twin-reference",
    "unresolved-attached-function-claim", "ambiguous-attached-function-claim",
    "stale-bootstrap-exemption",
})


@dataclass(frozen=True)
class Declaration:
    language: str
    path: str
    name: str
    arity: int
    line: int
    ordinal: int = 1
    kind: str = "function"
    owner_name: str | None = None
    offset: int = -1
    opening: int = -1
    parameter_labels: tuple[str, ...] = ()
    required_arity: int = 0

    @property
    def key(self) -> str:
        if self.kind == "property":
            return f"{self.path}::{self.name}@property#{self.ordinal}"
        return f"{self.path}::{self.name}/{self.arity}#{self.ordinal}"

    @property
    def owner(self) -> str:
        if self.owner_name:
            return self.owner_name
        stem = Path(self.path).stem
        return stem.replace("+Trace", "Trace")


@dataclass(frozen=True)
class Constant:
    language: str
    path: str
    name: str
    value: str | None
    display_value: str
    line: int
    owner_name: str | None = None

    @property
    def key(self) -> str:
        return f"{self.path}::{self.name}"

    @property
    def owner(self) -> str:
        return self.owner_name or Path(self.path).stem


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str
    line: int
    text: str
    identity: str

    def output(self) -> str:
        return f"{self.path}:{self.line}: {self.rule}: {self.text}"


@dataclass(frozen=True)
class ScanError:
    rule: str
    path: str
    line: int
    text: str

    def output(self) -> str:
        return f"{self.path}:{self.line}: {self.rule}: {self.text}"


@dataclass
class ScanResult:
    findings: list[Finding]
    counters: dict[str, int]
    stats: dict[str, int]
    errors: list[ScanError]
    missing_attached_claimants: set[str]
    bootstrap_unpaired_debts: set[str]


class _InvalidSourceEncoding(ValueError):
    def __init__(self, path: Path, detail: str):
        super().__init__(detail)
        self.path = path


@dataclass(frozen=True)
class TwinReference:
    language: str
    path: str
    line: int
    raw_target: str
    target_name: str
    target_owner: str | None
    attached_function: str | None
    claim_ordinal: int


@dataclass(frozen=True)
class CallSite:
    name: str
    arity: int
    owner: str | None
    path: str
    lexical_owner: str | None = None


def _paths(root: Path, globs: Iterable[str]) -> list[Path]:
    found: set[Path] = set()
    for pattern in globs:
        found.update(path for path in root.glob(pattern) if path.is_file())
    return sorted(found)


def _relative(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise _InvalidSourceEncoding(path, str(exc)) from exc


class _SourceSnapshot:
    """Operation-local immutable source view; discarded after one top-level scan."""

    def __init__(self) -> None:
        self._text: dict[Path, str] = {}
        self._masked: dict[tuple[Path, bool], str] = {}
        self._functions: dict[tuple[Path, str], tuple[Declaration, ...]] = {}
        self._properties: dict[tuple[Path, str], tuple[Declaration, ...]] = {}
        self._constants: dict[tuple[Path, str], tuple[Constant, ...]] = {}

    def text(self, path: Path) -> str:
        resolved = path.resolve()
        if resolved not in self._text:
            self._text[resolved] = _read(resolved)
        return self._text[resolved]

    def masked(self, path: Path, *, kotlin_templates: bool = False) -> str:
        resolved = path.resolve()
        key = (resolved, kotlin_templates)
        if key not in self._masked:
            self._masked[key] = _mask_non_code(
                self.text(resolved), kotlin_templates=kotlin_templates
            )
        return self._masked[key]

    def functions(self, root: Path, path: Path, language: str) -> tuple[Declaration, ...]:
        key = (path.resolve(), language)
        if key not in self._functions:
            self._functions[key] = _parse_functions_content(
                str(root.resolve()), str(key[0]), language, self.text(key[0]), self.masked(key[0])
            )
        return self._functions[key]

    def properties(self, root: Path, path: Path, language: str) -> tuple[Declaration, ...]:
        key = (path.resolve(), language)
        if key not in self._properties:
            self._properties[key] = _parse_properties_content(
                str(root.resolve()), str(key[0]), language, self.text(key[0]), self.masked(key[0])
            )
        return self._properties[key]

    def constants(self, root: Path, path: Path, language: str) -> tuple[Constant, ...]:
        key = (path.resolve(), language)
        if key not in self._constants:
            self._constants[key] = _parse_constants_content(
                str(root.resolve()), str(key[0]), language, self.text(key[0]), self.masked(key[0])
            )
        return self._constants[key]


def _mask_non_code(text: str, kotlin_templates: bool = False) -> str:
    """Replace comments and string contents with spaces, preserving newlines."""
    if kotlin_templates:
        return _mask_kotlin_template_code(text)
    out = list(text)
    i = 0
    state = "code"
    block_depth = 0
    quote = ""
    while i < len(text):
        if state == "code":
            if text.startswith("//", i):
                out[i] = out[i + 1] = " "
                i += 2
                state = "line"
            elif text.startswith("/*", i):
                out[i] = out[i + 1] = " "
                i += 2
                block_depth = 1
                state = "block"
            elif text.startswith('"""', i):
                out[i : i + 3] = "   "
                i += 3
                quote = '"""'
                state = "string"
            elif text[i] in "\"'":
                quote = text[i]
                out[i] = " "
                i += 1
                state = "string"
            else:
                i += 1
        elif state == "line":
            if text[i] == "\n":
                state = "code"
            else:
                out[i] = " "
            i += 1
        elif state == "block":
            if text.startswith("/*", i):
                out[i] = out[i + 1] = " "
                block_depth += 1
                i += 2
            elif text.startswith("*/", i):
                out[i] = out[i + 1] = " "
                block_depth -= 1
                i += 2
                if block_depth == 0:
                    state = "code"
            else:
                if text[i] != "\n":
                    out[i] = " "
                i += 1
        else:
            if quote == '"""' and text.startswith(quote, i):
                out[i : i + 3] = "   "
                i += 3
                state = "code"
            elif quote != '"""' and text[i] == "\\" and i + 1 < len(text):
                if text[i] != "\n":
                    out[i] = " "
                if text[i + 1] != "\n":
                    out[i + 1] = " "
                i += 2
            elif quote != '"""' and text[i] == quote:
                out[i] = " "
                i += 1
                state = "code"
            else:
                if text[i] != "\n":
                    out[i] = " "
                i += 1
    return "".join(out)


class _MalformedKotlinTemplate(ValueError):
    def __init__(self, offset: int):
        super().__init__("unterminated Kotlin string template")
        self.offset = offset


def _mask_kotlin_template_code(text: str) -> str:
    """Mask Kotlin non-code while retaining balanced ``${...}`` expressions.

    Kotlin string templates contain executable callsites, but their surrounding text—and strings or
    comments nested inside an expression—must remain invisible to the lexical call scanner.  The
    context stack keeps braces balanced and supports nested strings/templates.  A plain unterminated
    literal is masked through EOF; an unterminated template raises an explicit scan error because
    silently discarding its executable expression could hide a production callsite.
    """

    out = list(text)
    stack: list[dict[str, object]] = [{"kind": "code"}]
    i = 0

    def blank(start: int, end: int) -> None:
        for index in range(start, min(end, len(out))):
            if text[index] != "\n":
                out[index] = " "

    def fail_closed() -> str:
        string_starts = [
            int(context["start"])
            for context in stack
            if context["kind"] == "string"
        ]
        if string_starts:
            blank(min(string_starts), len(text))
        template_starts = [
            int(context["template_start"])
            for context in stack
            if context["kind"] == "string" and "template_start" in context
        ] + [
            int(context["start"])
            for context in stack
            if context["kind"] == "template"
        ]
        if template_starts:
            raise _MalformedKotlinTemplate(min(template_starts))
        return "".join(out)

    while i < len(text):
        context = stack[-1]
        kind = context["kind"]
        if kind in {"code", "template"}:
            if text.startswith("//", i):
                blank(i, i + 2)
                stack.append({"kind": "line"})
                i += 2
            elif text.startswith("/*", i):
                blank(i, i + 2)
                stack.append({"kind": "block", "depth": 1})
                i += 2
            elif text.startswith('"""', i):
                blank(i, i + 3)
                out[i] = "0"  # Occupy a containing call argument without exposing literal text.
                stack.append({"kind": "string", "quote": '"""', "start": i})
                i += 3
            elif text[i] in "\"'":
                blank(i, i + 1)
                out[i] = "0"  # String/character literals are one lexical argument token.
                stack.append({"kind": "string", "quote": text[i], "start": i})
                i += 1
            elif kind == "template" and text[i] == "{":
                context["depth"] = int(context["depth"]) + 1
                i += 1
            elif kind == "template" and text[i] == "}":
                context["depth"] = int(context["depth"]) - 1
                i += 1
                if context["depth"] == 0:
                    stack.pop()
            else:
                i += 1
        elif kind == "line":
            if text[i] == "\n":
                stack.pop()
            else:
                blank(i, i + 1)
            i += 1
        elif kind == "block":
            if text.startswith("/*", i):
                blank(i, i + 2)
                context["depth"] = int(context["depth"]) + 1
                i += 2
            elif text.startswith("*/", i):
                blank(i, i + 2)
                context["depth"] = int(context["depth"]) - 1
                i += 2
                if context["depth"] == 0:
                    stack.pop()
            else:
                blank(i, i + 1)
                i += 1
        else:
            quote = str(context["quote"])
            if quote == '"""' and text.startswith(quote, i):
                blank(i, i + 3)
                stack.pop()
                i += 3
            elif quote != '"""' and text[i] == "\n":
                return fail_closed()
            elif quote != '"""' and text[i] == "\\" and i + 1 < len(text):
                blank(i, i + 2)
                i += 2
            elif quote != '"""' and text[i] == quote:
                blank(i, i + 1)
                stack.pop()
                i += 1
            elif quote != "'" and text.startswith("${", i):
                blank(i, i + 1)
                context.setdefault("template_start", i)
                stack.append({"kind": "template", "depth": 1, "start": i})
                i += 2
            else:
                blank(i, i + 1)
                i += 1

    if any(context["kind"] in {"string", "template"} for context in stack):
        return fail_closed()
    return "".join(out)


def _arity(masked: str, opening: int) -> int | None:
    stack: list[str] = []
    pairs = {")": "(", "]": "[", "}": "{", ">": "<"}
    segments = 0
    segment_has_token = False
    i = opening + 1
    while i < len(masked):
        char = masked[i]
        if char == "(" or char == "[" or char == "{":
            stack.append(char)
        elif char == "<":
            # Parameter lists use angle brackets for types. Do not treat Kotlin/Swift arrows as generics.
            if i + 1 >= len(masked) or masked[i + 1] not in "= ":
                stack.append(char)
        elif char in pairs:
            if char == ")" and not stack:
                return segments + (1 if segment_has_token else 0)
            if stack and stack[-1] == pairs[char]:
                stack.pop()
        elif char == "," and not stack:
            if segment_has_token:
                segments += 1
            segment_has_token = False
        elif not char.isspace() and not stack:
            segment_has_token = True
        i += 1
    return None


def _swift_parameter_labels(masked: str, opening: int) -> tuple[str, ...]:
    labels: list[str] = []
    stack: list[str] = []
    start = opening + 1
    pairs = {")": "(", "]": "[", "}": "{"}
    i = start
    while i < len(masked):
        char = masked[i]
        if char in "([{":
            stack.append(char)
        elif char == ")" and not stack:
            segment = masked[start:i].strip()
            if segment:
                match = re.match(r"(_|[A-Za-z_][A-Za-z0-9_]*)\b", segment)
                labels.append(match.group(1) if match else "")
            return tuple(labels)
        elif char in pairs and stack and stack[-1] == pairs[char]:
            stack.pop()
        elif char == "," and not stack:
            segment = masked[start:i].strip()
            match = re.match(r"(_|[A-Za-z_][A-Za-z0-9_]*)\b", segment)
            labels.append(match.group(1) if match else "")
            start = i + 1
        i += 1
    return ()


def _parameter_segments(masked: str, opening: int) -> tuple[str, ...]:
    segments: list[str] = []
    stack: list[str] = []
    start = opening + 1
    pairs = {")": "(", "]": "[", "}": "{"}
    i = start
    while i < len(masked):
        char = masked[i]
        if char in "([{":
            stack.append(char)
        elif char == ")" and not stack:
            segment = masked[start:i].strip()
            if segment:
                segments.append(segment)
            return tuple(segments)
        elif char in pairs and stack and stack[-1] == pairs[char]:
            stack.pop()
        elif char == "," and not stack:
            segment = masked[start:i].strip()
            if segment:
                segments.append(segment)
            start = i + 1
        i += 1
    return ()


def _required_arity(masked: str, opening: int) -> int:
    required = 0
    for segment in _parameter_segments(masked, opening):
        stack: list[str] = []
        has_default = False
        pairs = {")": "(", "]": "[", "}": "{"}
        for char in segment:
            if char in "([{":
                stack.append(char)
            elif char in pairs and stack and stack[-1] == pairs[char]:
                stack.pop()
            elif char == "=" and not stack:
                has_default = True
                break
        if not has_default:
            required += 1
    return required


SWIFT_FUNC = re.compile(
    r"\bfunc\s+(`?[A-Za-z_][A-Za-z0-9_]*`?|[=!<>+\-*/%&|^~?.]+)\s*(?:<[^\n{}()]*>\s*)?\("
)
KOTLIN_FUNC = re.compile(
    r"\bfun\s+(?:<[^\n{}()]*>\s*)?([^\n{}()=]+?)\s*\("
)

TYPE_DECLARATION = {
    "swift": re.compile(r"\b(?:struct|class|enum|actor|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"),
    "kotlin": re.compile(
        r"\b(?:(?:data|sealed|enum|annotation|value)\s+)?(?:class|object|interface)\s+([A-Za-z_][A-Za-z0-9_]*)"
    ),
}


def _matching_brace(masked: str, opening: int) -> int:
    depth = 0
    for index in range(opening, len(masked)):
        if masked[index] == "{":
            depth += 1
        elif masked[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    return len(masked)


def _type_spans(masked: str, language: str) -> list[tuple[int, int, str]]:
    spans: list[tuple[int, int, str]] = []
    for match in TYPE_DECLARATION[language].finditer(masked):
        opening = masked.find("{", match.end())
        if opening < 0:
            continue
        # Do not attach a type to a later, unrelated declaration when its body is absent.
        next_decl = TYPE_DECLARATION[language].search(masked, match.end())
        if next_decl and next_decl.start() < opening:
            continue
        spans.append((opening, _matching_brace(masked, opening), match.group(1)))
    return spans


def _owner_at(spans: list[tuple[int, int, str]], offset: int, fallback: str) -> str:
    containing = [item for item in spans if item[0] < offset < item[1]]
    return max(containing, key=lambda item: item[0])[2] if containing else fallback


def _swift_module_owner(path: str) -> str | None:
    parts = Path(path).parts
    if len(parts) >= 4 and parts[0] == "Packages" and parts[2] == "Sources":
        return parts[1]
    return None


def _receiver_owner(header: str) -> str | None:
    name_match = re.search(r"(`?[A-Za-z_][A-Za-z0-9_]*`?)\s*$", header)
    if not name_match:
        return None
    prefix = header[: name_match.start()].rstrip()
    if not prefix.endswith("."):
        return None
    receiver = prefix[:-1].strip().rstrip("?")
    # The receiver can contain nested generics; the leading nominal type is the useful owner.
    names = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", receiver)
    return names[0] if names else None


def _parse_functions_content(
    root_string: str, path_string: str, language: str, text: str, masked: str | None = None
) -> tuple[Declaration, ...]:
    root = Path(root_string)
    path = Path(path_string)
    masked = masked if masked is not None else _mask_non_code(text)
    pattern = SWIFT_FUNC if language == "swift" else KOTLIN_FUNC
    rel = _relative(root, path)
    fallback_owner = path.stem.replace("+Trace", "Trace")
    spans = _type_spans(masked, language)
    out: list[Declaration] = []
    ordinals: Counter[tuple[str, int]] = Counter()
    for match in pattern.finditer(masked):
        arity = _arity(masked, match.end() - 1)
        if arity is None:
            continue
        header = match.group(1)
        if language == "kotlin":
            name_match = re.search(r"(`?[A-Za-z_][A-Za-z0-9_]*`?)\s*$", header)
            if not name_match:
                continue
            name = name_match.group(1).strip("`")
            name_offset = match.start(1) + name_match.start(1)
            receiver = _receiver_owner(header)
        else:
            name = header.strip("`")
            name_offset = match.start(1)
            receiver = None
        ordinals[(name, arity)] += 1
        out.append(
            Declaration(
                language=language,
                path=rel,
                name=name,
                arity=arity,
                line=text.count("\n", 0, match.start()) + 1,
                ordinal=ordinals[(name, arity)],
                owner_name=receiver or _owner_at(spans, match.start(), fallback_owner),
                offset=name_offset,
                opening=match.end() - 1,
                parameter_labels=(
                    _swift_parameter_labels(masked, match.end() - 1)
                    if language == "swift" else ()
                ),
                required_arity=_required_arity(masked, match.end() - 1),
            )
        )
    return tuple(out)


def parse_functions(root: Path, path: Path, language: str) -> list[Declaration]:
    return list(
        _parse_functions_content(
            str(root.resolve()), str(path.resolve()), language, _read(path)
        )
    )


def _parse_properties_content(
    root_string: str, path_string: str, language: str, text: str, masked: str | None = None
) -> tuple[Declaration, ...]:
    """Inventory computed properties/getters, excluding stored fields."""
    root = Path(root_string)
    path = Path(path_string)
    masked = masked if masked is not None else _mask_non_code(text)
    rel = _relative(root, path)
    fallback_owner = path.stem.replace("+Trace", "Trace")
    spans = _type_spans(masked, language)
    if language == "swift":
        pattern = re.compile(
            r"\bvar\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*[^=\n{]+\{"
        )
    else:
        pattern = re.compile(
            r"\b(?:val|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b"
            r"(?:\s*:\s*[^=\n{]+)?\s*(?:\n[ \t]*)?get\s*\(\s*\)"
        )
    out: list[Declaration] = []
    ordinals: Counter[str] = Counter()
    for match in pattern.finditer(masked):
        name = match.group(1)
        ordinals[name] += 1
        out.append(
            Declaration(
                language=language,
                path=rel,
                name=name,
                arity=0,
                line=text.count("\n", 0, match.start()) + 1,
                ordinal=ordinals[name],
                kind="property",
                owner_name=_owner_at(spans, match.start(), fallback_owner),
                offset=match.start(1),
            )
        )
    return tuple(out)


def parse_properties(root: Path, path: Path, language: str) -> list[Declaration]:
    return list(
        _parse_properties_content(
            str(root.resolve()), str(path.resolve()), language, _read(path)
        )
    )


NUMBER_PATTERN = (
    r"(?:0[xX][0-9A-Fa-f_]+[lL]?|0[bB][01_]+[lL]?|0[oO][0-7_]+[lL]?|"
    r"(?:\d[\d_]*(?:\.[\d_]*)?|\.[\d_]+)(?:[eE][-+]?\d[\d_]*)?[fFdDlL]?)"
)
NUMBER_TOKEN = re.compile(NUMBER_PATTERN)


class _NumberExpression:
    def __init__(self, raw: str):
        self.raw = raw
        self.tokens = re.findall(
            NUMBER_PATTERN + r"|[()+\-*/]",
            raw,
        )
        self.index = 0

    def parse(self) -> Decimal:
        compact = re.sub(r"\s+", "", self.raw)
        if "".join(self.tokens) != compact or not self.tokens:
            raise InvalidOperation
        value = self._sum()
        if self.index != len(self.tokens):
            raise InvalidOperation
        return value

    def _sum(self) -> Decimal:
        value = self._product()
        while self._peek() in {"+", "-"}:
            operator = self._take()
            right = self._product()
            value = value + right if operator == "+" else value - right
        return value

    def _product(self) -> Decimal:
        value = self._unary()
        while self._peek() in {"*", "/"}:
            operator = self._take()
            right = self._unary()
            if operator == "*":
                value *= right
            else:
                if right == 0:
                    raise InvalidOperation
                value /= right
        return value

    def _unary(self) -> Decimal:
        if self._peek() in {"+", "-"}:
            operator = self._take()
            value = self._unary()
            return value if operator == "+" else -value
        if self._peek() == "(":
            self._take()
            value = self._sum()
            if self._take() != ")":
                raise InvalidOperation
            return value
        token = self._take()
        if not NUMBER_TOKEN.fullmatch(token):
            raise InvalidOperation
        number = token.replace("_", "").rstrip("fFdDlL")
        if number.lower().startswith(("0x", "0b", "0o")):
            return Decimal(int(number, 0))
        return Decimal(number)

    def _peek(self) -> str | None:
        return self.tokens[self.index] if self.index < len(self.tokens) else None

    def _take(self) -> str:
        if self.index >= len(self.tokens):
            raise InvalidOperation
        token = self.tokens[self.index]
        self.index += 1
        return token


def _initializer(text: str, start: int) -> str:
    """Return exactly one single-line constant initializer, without its terminator/comment."""
    out: list[str] = []
    quote: str | None = None
    escaped = False
    depth = 0
    index = start
    while index < len(text):
        char = text[index]
        if quote:
            out.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            index += 1
            continue
        if text.startswith("//", index):
            break
        if char in {'"', "'"}:
            quote = char
            out.append(char)
        elif char == "(":
            depth += 1
            out.append(char)
        elif char == ")":
            depth = max(0, depth - 1)
            out.append(char)
        elif char in "\n;," and depth == 0:
            break
        elif char == "}" and depth == 0:
            break
        else:
            out.append(char)
        index += 1
    return "".join(out).strip().rstrip(",").strip()


def _literal(raw: str) -> tuple[str, str] | None:
    value = raw.strip()
    if re.fullmatch(r'"(?:\\.|[^"\\])*"', value):
        token = value
        token_for_json = re.sub(
            r"\\u\{([0-9A-Fa-f]{1,8})\}",
            lambda item: "\\u" + item.group(1).zfill(4),
            token,
        )
        try:
            decoded = json.loads(token_for_json)
        except json.JSONDecodeError:
            decoded = token[1:-1]
        return f"string:{decoded}", token
    if value in {"true", "false"}:
        return f"bool:{value}", value
    if value in {"nil", "null"}:
        return "null", value
    try:
        number = _NumberExpression(value).parse()
        return f"number:{number.normalize()}", value
    except (InvalidOperation, ZeroDivisionError):
        return None


def _parse_constants_content(
    root_string: str, path_string: str, language: str, text: str, masked: str | None = None
) -> tuple[Constant, ...]:
    root = Path(root_string)
    path = Path(path_string)
    masked = masked if masked is not None else _mask_non_code(text)
    if language == "swift":
        pattern = re.compile(r"\blet\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=\n]+)?=")
    else:
        pattern = re.compile(r"\bconst\s+val\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=\n]+)?=")
    rel = _relative(root, path)
    fallback_owner = path.stem.replace("+Trace", "Trace")
    spans = _type_spans(masked, language)
    out: list[Constant] = []
    for match in pattern.finditer(masked):
        if language == "swift":
            line_start = text.rfind("\n", 0, match.start()) + 1
            prefix = text[line_start : match.start()]
            # Kotlin's `const val` has static storage. Pair it only with a Swift `static
            # let` or a file-scope declaration, never with a local/instance `let`.
            if "static" not in prefix.split() and len(prefix) - len(prefix.lstrip()) > 4:
                continue
        raw = _initializer(text, match.end())
        parsed = _literal(raw)
        canonical, display = parsed if parsed is not None else (None, raw or "<empty>")
        out.append(
            Constant(
                language,
                rel,
                match.group(1),
                canonical,
                display,
                text.count("\n", 0, match.start()) + 1,
                _owner_at(spans, match.start(), fallback_owner),
            )
        )
    return tuple(out)


def parse_constants(root: Path, path: Path, language: str) -> list[Constant]:
    return list(
        _parse_constants_content(
            str(root.resolve()), str(path.resolve()), language, _read(path)
        )
    )


def _inventory(
    root: Path,
    snapshot: _SourceSnapshot | None = None,
) -> tuple[
    list[Path],
    list[Path],
    list[Declaration],
    list[Declaration],
    list[Declaration],
    list[Declaration],
    list[Constant],
    list[Constant],
]:
    snapshot = snapshot or _SourceSnapshot()
    swift_files = _paths(root, SWIFT_GLOBS)
    kotlin_files = _paths(root, KOTLIN_GLOBS)
    swift_functions: list[Declaration] = []
    kotlin_functions: list[Declaration] = []
    swift_properties: list[Declaration] = []
    kotlin_properties: list[Declaration] = []
    swift_constants: list[Constant] = []
    kotlin_constants: list[Constant] = []
    for paths, language, functions, properties, constants in (
        (swift_files, "swift", swift_functions, swift_properties, swift_constants),
        (kotlin_files, "kotlin", kotlin_functions, kotlin_properties, kotlin_constants),
    ):
        for path in paths:
            functions.extend(snapshot.functions(root, path, language))
            properties.extend(snapshot.properties(root, path, language))
            constants.extend(snapshot.constants(root, path, language))
    return (
        swift_files,
        kotlin_files,
        swift_functions,
        kotlin_functions,
        swift_properties,
        kotlin_properties,
        swift_constants,
        kotlin_constants,
    )


def _annotation_count(files: list[Path], snapshot: _SourceSnapshot | None = None) -> int:
    snapshot = snapshot or _SourceSnapshot()
    pattern = re.compile(r"\b(?:twin|parity)\b", re.I)
    return sum(len(pattern.findall(snapshot.text(path))) for path in files)


def _normal_name(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", name.lower())


def _comment_blocks(text: str, language: str) -> list[tuple[int, int, str]]:
    out: list[tuple[int, int, str]] = []
    for match in re.finditer(r"/\*[\s\S]*?\*/", text):
        start = text.count("\n", 0, match.start()) + 1
        end = text.count("\n", 0, match.end()) + 1
        out.append((start, end, match.group(0)))
    for match in re.finditer(r"(?m)(?:^[ \t]*//[^\n]*(?:\n|$))+", text):
        start = text.count("\n", 0, match.start()) + 1
        end = text.count("\n", 0, match.end()) + 1
        out.append((start, end, match.group(0)))
    return sorted(out)


REFERENCE_PATTERNS = (
    re.compile(r"\b(?:Kotlin|Swift)(?:'s)?\s+twin\s*(?:is\s*|of\s*|:\s*)?(?:the\s+)?`([^`]+)`", re.I),
    re.compile(r"\btwin\s+of\s+(?:the\s+)?(?:Kotlin|Swift)(?:'s)?\s+`([^`]+)`", re.I),
    re.compile(r"\bmirrors\s+(?:Kotlin|Swift)(?:'s)?\s+`([^`]+)`", re.I),
    re.compile(
        r"\b(?:Kotlin|Swift)(?:'s)?\s+twin\s*(?:is\s*|:\s*)?"
        r"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)",
        re.I,
    ),
)


def _target(raw: str) -> tuple[str, str | None] | None:
    value = raw.strip()
    if "/" in value and value.lower().endswith((".swift", ".kt")):
        return Path(value).stem, None
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)*", value):
        return None
    pieces = value.split(".")
    if pieces[-1].lower() in {"swift", "kt"} and len(pieces) >= 2:
        return pieces[-2], None
    name = pieces[-1].split("(", 1)[0]
    owner = pieces[-2] if len(pieces) > 1 else None
    if len(pieces) > 2 and all(piece[:1].islower() for piece in pieces[:-1]):
        owner = None  # package-qualified type, e.g. com.noop.protocol.DeviceConfigWriteGate
    elif name[:1].isupper():
        owner = None  # module/type-qualified type, not an Owner.member reference
    return name, owner


def parse_twin_references(
    root: Path,
    files: list[Path],
    language: str,
    functions: list[Declaration],
    snapshot: _SourceSnapshot | None = None,
) -> list[TwinReference]:
    snapshot = snapshot or _SourceSnapshot()
    by_path: dict[str, list[Declaration]] = defaultdict(list)
    for declaration in functions:
        by_path[declaration.path].append(declaration)
    out: list[TwinReference] = []
    expected = "kotlin" if language == "swift" else "swift"
    for path in files:
        rel = _relative(root, path)
        text = snapshot.text(path)
        claim_ordinals: Counter[tuple[str, str | None]] = Counter()
        for start, end, comment in _comment_blocks(text, language):
            if "twin" not in comment.lower() or expected not in comment.lower():
                continue
            # Remove line-doc decoration without changing offsets, so wrapped unquoted
            # references remain machine-readable and line reporting stays exact.
            searchable = re.sub(
                r"(?m)^(\s*)(?:///|//|/\*\*?|\*) ?",
                lambda match: " " * len(match.group(0)),
                comment,
            )
            raw_targets: list[tuple[str, int]] = []
            for pattern in REFERENCE_PATTERNS:
                raw_targets.extend((match.group(1), match.start(1)) for match in pattern.finditer(searchable))
            raw_targets.sort(key=lambda item: item[1])

            parsed_targets: list[tuple[str, int, str, str | None]] = []
            seen: set[str] = set()
            for raw, offset in raw_targets:
                if raw in seen:
                    continue
                seen.add(raw)
                parsed = _target(raw)
                if parsed is None:
                    continue
                name, owner = parsed
                parsed_targets.append((raw, offset, name, owner))

            nearby_declaration = next(
                (decl.key for decl in by_path[rel] if end <= decl.line <= end + 4),
                None,
            )
            # A prose block can mention older alternatives before stating the
            # authoritative twin.  Only its nearest function-shaped claim is
            # attached to the following declaration.  File/type references
            # remain repository-wide references and never claim a function.
            attachable = [
                item for item in parsed_targets
                if item[3] is not None or item[2][:1].islower()
            ]
            attached_target = attachable[-1] if nearby_declaration and attachable else None

            for raw, offset, name, owner in parsed_targets:
                attached = (
                    nearby_declaration
                    if attached_target is not None and (raw, offset, name, owner) == attached_target
                    else None
                )
                claim_key = (raw, attached)
                claim_ordinals[claim_key] += 1
                line = start + searchable.count("\n", 0, offset)
                out.append(
                    TwinReference(
                        language,
                        rel,
                        line,
                        raw,
                        name,
                        owner,
                        attached,
                        claim_ordinals[claim_key],
                    )
                )
    return out


def _resolve(reference: TwinReference, targets: list[Declaration]) -> list[Declaration]:
    matches = [decl for decl in targets if _normal_name(decl.name) == _normal_name(reference.target_name)]
    if reference.target_owner:
        wanted = _normal_name(reference.target_owner)
        matches = [
            decl for decl in matches
            if wanted in {
                _normal_name(decl.owner),
                _normal_name(_swift_module_owner(decl.path) or ""),
            }
        ]
    selector = re.search(r"\(([^)]*)\)\s*$", reference.raw_target)
    if selector:
        labels = tuple(
            part.strip().rstrip(":")
            for part in selector.group(1).split(":")
            if part.strip()
        )
        if labels:
            labelled = [decl for decl in matches if decl.parameter_labels[: len(labels)] == labels]
            matches = labelled
    return matches


def attached_function_resolutions(
    references: Iterable[TwinReference],
    swift_functions: list[Declaration],
    kotlin_functions: list[Declaration],
) -> dict[TwinReference, tuple[Declaration, ...]]:
    """Resolve every attached claim, including missing and ambiguous claims."""
    result: dict[TwinReference, tuple[Declaration, ...]] = {}
    for reference in references:
        if reference.attached_function is None:
            continue
        targets = kotlin_functions if reference.language == "swift" else swift_functions
        candidates = _resolve(reference, targets)
        result[reference] = tuple(candidates)
    return result


def resolved_attached_function_pairs(
    references: Iterable[TwinReference],
    swift_functions: list[Declaration],
    kotlin_functions: list[Declaration],
    *,
    resolutions: dict[TwinReference, tuple[Declaration, ...]] | None = None,
) -> dict[tuple[str, str], list[TwinReference]]:
    """Resolve attached source claims into the exact pairs they declare.

    Both map bootstrap and normal scans use this function so a source comment
    cannot be retargeted, added, or removed independently of the checked map.
    Ambiguous and unresolved claims are deliberately omitted here; the normal
    dead-reference audit reports those claims separately.
    """
    pairs: dict[tuple[str, str], list[TwinReference]] = defaultdict(list)
    if resolutions is None:
        resolutions = attached_function_resolutions(
            references, swift_functions, kotlin_functions
        )
    for reference, resolved in resolutions.items():
        if len(resolved) != 1:
            continue
        pair = (
            (reference.attached_function, resolved[0].key)
            if reference.language == "swift"
            else (resolved[0].key, reference.attached_function)
        )
        pairs[pair].append(reference)
    return pairs


def resolved_file_pairs(
    function_pairs: Iterable[tuple[str, str]],
    swift_functions: list[Declaration],
    kotlin_functions: list[Declaration],
) -> set[tuple[str, str]]:
    """Derive file authority from the same resolved function pairs everywhere."""
    swift_by_key = {item.key: item for item in swift_functions}
    kotlin_by_key = {item.key: item for item in kotlin_functions}
    return {
        (swift_by_key[swift_key].path, kotlin_by_key[kotlin_key].path)
        for swift_key, kotlin_key in function_pairs
        if swift_key in swift_by_key and kotlin_key in kotlin_by_key
    }


def _symbol_owners(
    root: Path,
    files: list[Path],
    declarations: list[Declaration],
    snapshot: _SourceSnapshot | None = None,
) -> dict[str, set[str]]:
    snapshot = snapshot or _SourceSnapshot()
    symbols: dict[str, set[str]] = defaultdict(set)
    for item in declarations:
        owners = {_normal_name(item.owner), _normal_name(Path(item.path).stem)}
        module = _swift_module_owner(item.path)
        if module:
            owners.add(_normal_name(module))
        symbols[_normal_name(item.name)].update(owners)
    for path in files:
        file_owner = _normal_name(path.stem)
        symbols[file_owner].add(file_owner)
        language = "swift" if path.suffix == ".swift" else "kotlin"
        text = snapshot.text(path)
        masked = snapshot.masked(path)
        spans = _type_spans(masked, language)
        for _, _, name in spans:
            symbols[_normal_name(name)].add(file_owner)
        declaration = re.compile(
            r"\b(?:typealias|let|var|val)\s+([A-Za-z_][A-Za-z0-9_]*)\b"
        )
        for match in declaration.finditer(masked):
            owner = _owner_at(spans, match.start(), path.stem)
            symbols[_normal_name(match.group(1))].update((_normal_name(owner), file_owner))
        if language == "kotlin":
            for type_match in TYPE_DECLARATION[language].finditer(masked):
                opening = masked.find("{", type_match.end())
                header_end = opening if opening >= 0 else masked.find("\n", type_match.end())
                if header_end < 0:
                    header_end = len(masked)
                header = masked[type_match.end():header_end]
                for property_match in re.finditer(r"\b(?:val|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b", header):
                    symbols[_normal_name(property_match.group(1))].update(
                        (_normal_name(type_match.group(1)), file_owner)
                    )
    return symbols


def _reference_resolves(reference: TwinReference, symbols: dict[str, set[str]]) -> bool:
    owners = symbols.get(_normal_name(reference.target_name), set())
    if not owners:
        return False
    return reference.target_owner is None or _normal_name(reference.target_owner) in owners


def _symbol_names(files: list[Path], functions: list[Declaration]) -> set[str]:
    """Compatibility helper retained for callers outside this module."""
    names = {_normal_name(item.name) for item in functions}
    names.update(_normal_name(path.stem) for path in files)
    declaration = re.compile(
        r"\b(?:struct|class|enum|actor|protocol|object|interface|typealias|let|var|val)\s+([A-Za-z_][A-Za-z0-9_]*)\b"
    )
    for path in files:
        masked = _mask_non_code(_read(path))
        names.update(_normal_name(match.group(1)) for match in declaration.finditer(masked))
    return names


def _constant_pairing(
    swift: list[Constant], kotlin: list[Constant], file_pairs: set[tuple[str, str]] | None = None
) -> tuple[list[tuple[Constant, Constant]], list[tuple[str, list[Constant], list[Constant]]]]:
    """Pair normalized constant names, preferring type owner and then mapped/same-stem files."""
    file_pairs = file_pairs or set()
    sw_by_name: dict[str, list[Constant]] = defaultdict(list)
    kt_by_name: dict[str, list[Constant]] = defaultdict(list)
    for item in swift:
        sw_by_name[_normal_name(item.name)].append(item)
    for item in kotlin:
        kt_by_name[_normal_name(item.name)].append(item)
    pairs: list[tuple[Constant, Constant]] = []
    ambiguous: list[tuple[str, list[Constant], list[Constant]]] = []
    for name in sorted(sw_by_name.keys() & kt_by_name.keys()):
        left = list(sw_by_name[name])
        right = list(kt_by_name[name])

        def consume(predicate) -> None:
            nonlocal left, right
            edges = [
                (sw, kt)
                for sw in left
                for kt in right
                if predicate(sw, kt) and (sw.key, kt.key) not in CONSTANT_NON_TWIN_PAIRS
            ]
            left_degree = Counter(id(sw) for sw, _ in edges)
            right_degree = Counter(id(kt) for _, kt in edges)
            chosen = [(sw, kt) for sw, kt in edges if left_degree[id(sw)] == 1 and right_degree[id(kt)] == 1]
            pairs.extend(chosen)
            chosen_left = {id(sw) for sw, _ in chosen}
            chosen_right = {id(kt) for _, kt in chosen}
            left = [item for item in left if id(item) not in chosen_left]
            right = [item for item in right if id(item) not in chosen_right]

        consume(lambda sw, kt: _normal_name(sw.owner) == _normal_name(kt.owner))
        consume(lambda sw, kt: (sw.path, kt.path) in file_pairs)
        if (len(left) == 1 and len(right) == 1
                and (left[0].key, right[0].key) not in CONSTANT_NON_TWIN_PAIRS):
            pairs.append((left.pop(), right.pop()))
        allowed_edges = [
            (sw, kt)
            for sw in left
            for kt in right
            if (sw.key, kt.key) not in CONSTANT_NON_TWIN_PAIRS
        ]
        if allowed_edges:
            allowed_left = {id(sw) for sw, _ in allowed_edges}
            allowed_right = {id(kt) for _, kt in allowed_edges}
            ambiguous.append((
                name,
                sorted((item for item in left if id(item) in allowed_left), key=lambda item: item.key),
                sorted((item for item in right if id(item) in allowed_right), key=lambda item: item.key),
            ))
    return sorted(pairs, key=lambda pair: (pair[0].key, pair[1].key)), ambiguous


def _property_candidates(
    swift: list[Declaration], kotlin: list[Declaration]
) -> list[tuple[Declaration, Declaration]]:
    sw_by_identity: dict[tuple[str, str, str], list[Declaration]] = defaultdict(list)
    kt_by_identity: dict[tuple[str, str, str], list[Declaration]] = defaultdict(list)
    for item in swift:
        sw_by_identity[(_normal_name(item.name), _normal_name(item.owner), _normal_name(Path(item.path).stem))].append(item)
    for item in kotlin:
        kt_by_identity[(_normal_name(item.name), _normal_name(item.owner), _normal_name(Path(item.path).stem))].append(item)
    return [
        (sw_by_identity[key][0], kt_by_identity[key][0])
        for key in sorted(sw_by_identity.keys() & kt_by_identity.keys())
        if len(sw_by_identity[key]) == 1 and len(kt_by_identity[key]) == 1
    ]


def _reference_declarations(
    root: Path,
    inventory_declarations: tuple[
        list[Declaration], list[Declaration], list[Declaration], list[Declaration]
    ] | None = None,
    snapshot: _SourceSnapshot | None = None,
) -> tuple[list[Path], list[Declaration]]:
    snapshot = snapshot or _SourceSnapshot()
    if inventory_declarations is None:
        inventory = _inventory(root, snapshot)
        inventory_declarations = (inventory[2], inventory[3], inventory[4], inventory[5])
    files = _paths(root, REFERENCE_GLOBS)
    governed: dict[str, list[Declaration]] = defaultdict(list)
    for source_declarations in inventory_declarations:
        for item in source_declarations:
            governed[item.path].append(item)
    declarations: list[Declaration] = []
    for path in files:
        relative = _relative(root, path)
        existing = governed.get(relative, [])
        if existing:
            declarations.extend(existing)
            continue
        language = "swift" if path.suffix == ".swift" else "kotlin"
        declarations.extend(snapshot.functions(root, path, language))
        declarations.extend(snapshot.properties(root, path, language))
    return files, declarations


def build_twin_map(
    root: Path,
    inventory: tuple | None = None,
    snapshot: _SourceSnapshot | None = None,
) -> dict:
    """Derive the full internal semantic inventory from source."""
    root = root.resolve()
    snapshot = snapshot or _SourceSnapshot()
    inventory = inventory or _inventory(root, snapshot)
    (
        sw_files,
        kt_files,
        sw_funcs,
        kt_funcs,
        sw_properties,
        kt_properties,
        sw_consts,
        kt_consts,
    ) = inventory
    reference_files, reference_declarations = _reference_declarations(
        root, (sw_funcs, kt_funcs, sw_properties, kt_properties), snapshot
    )
    reference_functions = [item for item in reference_declarations if item.kind == "function"]
    repo_sw_funcs = [item for item in reference_functions if item.language == "swift"]
    repo_kt_funcs = [item for item in reference_functions if item.language == "kotlin"]
    refs = parse_twin_references(root, sw_files, "swift", sw_funcs, snapshot) + parse_twin_references(root, kt_files, "kotlin", kt_funcs, snapshot)
    pairs = set(resolved_attached_function_pairs(refs, repo_sw_funcs, repo_kt_funcs))

    paired_sw = {left for left, _ in pairs}
    paired_kt = {right for _, right in pairs}
    file_pairs = sorted(resolved_file_pairs(pairs, repo_sw_funcs, repo_kt_funcs))
    property_pairs = _property_candidates(sw_properties, kt_properties)
    constant_pairs, _ = _constant_pairing(sw_consts, kt_consts, set(file_pairs))
    paired_sw_files = {left for left, _ in file_pairs}
    paired_kt_files = {right for _, right in file_pairs}

    sw_unpaired = [item for item in sw_funcs if item.key not in paired_sw]
    kt_unpaired = [item for item in kt_funcs if item.key not in paired_kt]
    return {
        "file_pairs": [
            {"swift": left, "kotlin": right}
            for left, right in file_pairs
        ],
        "function_pairs": [
            {"swift": left, "kotlin": right}
            for left, right in sorted(pairs)
        ],
        "property_pairs": [
            {"swift": left.key, "kotlin": right.key}
            for left, right in property_pairs
        ],
        "constant_pairs": [
            {"swift": left.key, "kotlin": right.key}
            for left, right in constant_pairs
        ],
        "unpaired_files": {
            "swift": [_relative(root, path) for path in sw_files if _relative(root, path) not in paired_sw_files],
            "kotlin": [_relative(root, path) for path in kt_files if _relative(root, path) not in paired_kt_files],
        },
        "unpaired_functions": {
            "swift": [item.key for item in sw_unpaired],
            "kotlin": [item.key for item in kt_unpaired],
        },
        "unpaired_properties": {
            "swift": [item.key for item in sw_properties if item.key not in {left.key for left, _ in property_pairs}],
            "kotlin": [item.key for item in kt_properties if item.key not in {right.key for _, right in property_pairs}],
        },
    }


SEMANTIC_AUTHORITY_SETS = (
    "files",
    "functions",
    "properties",
    "constants",
    "file_pairs",
    "function_pairs",
    "property_pairs",
    "constant_pairs",
    "unpaired_files",
    "unpaired_functions",
    "unpaired_properties",
    "unpaired_constants",
)


def _canonical_sha256(value: object) -> str:
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def semantic_authority(
    root: Path,
    *,
    expanded: dict | None = None,
    inventory: tuple | None = None,
    snapshot: _SourceSnapshot | None = None,
) -> dict[str, list[str]]:
    """Return exact canonical semantic sets, excluding descriptions and suggestions."""
    root = root.resolve()
    snapshot = snapshot or _SourceSnapshot()
    inventory = inventory or _inventory(root, snapshot)
    expanded = expanded or build_twin_map(root, inventory, snapshot)
    (
        sw_files,
        kt_files,
        sw_funcs,
        kt_funcs,
        sw_properties,
        kt_properties,
        sw_constants,
        kt_constants,
    ) = inventory

    def pairs(name: str) -> list[str]:
        return sorted(
            f"{item['swift']}\u0000{item['kotlin']}"
            for item in expanded[name]
        )

    def both(name: str) -> list[str]:
        group = expanded[name]
        return sorted([f"swift\u0000{item}" for item in group["swift"]]
                      + [f"kotlin\u0000{item}" for item in group["kotlin"]])

    paired_constant_keys = {
        item[side]
        for item in expanded["constant_pairs"]
        for side in ("swift", "kotlin")
    }

    return {
        "files": sorted(
            [f"swift\u0000{_relative(root, path)}" for path in sw_files]
            + [f"kotlin\u0000{_relative(root, path)}" for path in kt_files]
        ),
        "functions": sorted(
            [f"swift\u0000{item.key}" for item in sw_funcs]
            + [f"kotlin\u0000{item.key}" for item in kt_funcs]
        ),
        "properties": sorted(
            [f"swift\u0000{item.key}" for item in sw_properties]
            + [f"kotlin\u0000{item.key}" for item in kt_properties]
        ),
        "constants": sorted(
            [f"swift\u0000{item.key}" for item in sw_constants]
            + [f"kotlin\u0000{item.key}" for item in kt_constants]
        ),
        "file_pairs": pairs("file_pairs"),
        "function_pairs": pairs("function_pairs"),
        "property_pairs": pairs("property_pairs"),
        "constant_pairs": pairs("constant_pairs"),
        "unpaired_files": both("unpaired_files"),
        "unpaired_functions": both("unpaired_functions"),
        "unpaired_properties": both("unpaired_properties"),
        "unpaired_constants": sorted(
            [f"swift\u0000{item.key}" for item in sw_constants if item.key not in paired_constant_keys]
            + [f"kotlin\u0000{item.key}" for item in kt_constants if item.key not in paired_constant_keys]
        ),
    }


def authority_manifest(sets: dict[str, list[str]]) -> dict[str, dict[str, object]]:
    return {
        name: {"count": len(sets[name]), "sha256": _canonical_sha256(sets[name])}
        for name in SEMANTIC_AUTHORITY_SETS
    }


def _working_tree_added_lines(root: Path) -> dict[str, set[int]]:
    """Return branch/worktree additions for actionable local diagnostics."""
    try:
        try:
            base = subprocess.check_output(
                ["git", "merge-base", "HEAD", "origin/main"],
                cwd=root,
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except subprocess.CalledProcessError:
            base = "HEAD"
        output = subprocess.check_output(
            ["git", "diff", "--no-ext-diff", "--unified=0", base, "--"],
            cwd=root,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return {}
    added: dict[str, set[int]] = defaultdict(set)
    path: str | None = None
    for line in output.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
            continue
        if not line.startswith("@@ ") or path is None:
            continue
        match = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if match is None:
            continue
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        added[path].update(range(start, start + count))
    return added


def _new_unpaired_diagnostics(
    root: Path,
    semantic_sets: dict[str, list[str]],
    declarations: Iterable[Declaration],
) -> list[Finding]:
    """Name locally added one-sided declarations while compact authority is stale."""
    added = _working_tree_added_lines(root)
    unpaired = set(semantic_sets["unpaired_functions"])
    return [
        _finding(
            "add-unpaired-function",
            declaration.path,
            declaration.line,
            f"new one-sided {declaration.language} function {declaration.key}",
            f"add-unpaired-function|{declaration.language}|{declaration.key}",
        )
        for declaration in declarations
        if f"{declaration.language}\0{declaration.key}" in unpaired
        and declaration.line in added.get(declaration.path, set())
    ]


def build_compact_twin_map(root: Path) -> dict:
    """Freeze derived semantic sets without checking in repeated inventory rows."""
    manifest = authority_manifest(semantic_authority(root))
    return {
        "schema_version": 3,
        "derivation": "parity_ledger.build_twin_map/v3",
        "scope": {
            "swift_roots": [glob.split("/**", 1)[0] for glob in SWIFT_GLOBS],
            "kotlin_roots": [glob.split("/**", 1)[0] for glob in KOTLIN_GLOBS],
        },
        "authority": manifest,
    }


def expand_twin_map(root: Path, twin_map: dict) -> tuple[dict, list[str]]:
    """Expand v3 from source and report every frozen-authority mismatch."""
    if twin_map.get("schema_version") != 3:
        return twin_map, []
    inventory = _inventory(root)
    expanded = build_twin_map(root, inventory)
    checked = twin_map.get("authority", {})
    current = authority_manifest(
        semantic_authority(root, expanded=expanded, inventory=inventory)
    )
    drift = [
        key for key in SEMANTIC_AUTHORITY_SETS
        if not isinstance(checked, dict) or checked.get(key) != current[key]
    ]
    return expanded, drift


def _finding(rule: str, path: str, line: int, text: str, identity: str) -> Finding:
    return Finding(rule, path, line, text, f"{rule}|{identity}")


def _twin_map_consistency_findings(
    twin_map: dict,
    *,
    files: set[str],
    functions: set[str],
    properties: set[str],
) -> list[Finding]:
    """Validate the curated map itself instead of trusting it as inventory truth.

    Map regeneration is intentionally not used here: hand-curated evidence and
    cross-name pairs are authoritative, but every asserted or explicitly unpaired
    key must still resolve exactly and occur in only one state.
    """

    findings: list[Finding] = []
    categories = (
        ("file_pairs", "unpaired_files", files, "file"),
        ("function_pairs", "unpaired_functions", functions, "function"),
        ("property_pairs", "unpaired_properties", properties, "property"),
    )
    for pair_name, unpaired_name, inventory, kind in categories:
        pairs = twin_map.get(pair_name, [])
        unpaired = twin_map.get(unpaired_name, {})
        if not isinstance(pairs, list) or not isinstance(unpaired, dict):
            findings.append(
                _finding(
                    "malformed-twin-map", DEFAULT_MAP.relative_to(ROOT).as_posix(), 1,
                    f"{pair_name}/{unpaired_name} must be an array/object",
                    f"{pair_name}|{unpaired_name}",
                )
            )
            continue
        for side in ("swift", "kotlin"):
            paired = [entry.get(side) for entry in pairs if isinstance(entry, dict)]
            paired_keys = [key for key in paired if isinstance(key, str)]
            unpaired_keys = unpaired.get(side, [])
            if not isinstance(unpaired_keys, list):
                findings.append(
                    _finding(
                        "malformed-twin-map", DEFAULT_MAP.relative_to(ROOT).as_posix(), 1,
                        f"{unpaired_name}.{side} must be an array",
                        f"{unpaired_name}|{side}",
                    )
                )
                continue
            for key, count in sorted(Counter(paired_keys).items()):
                # A source file may intentionally contain declarations paired
                # with more than one counterpart file. Declaration targets,
                # however, are one-to-one and may never be reused.
                if kind != "file" and count > 1:
                    path = key.split("::", 1)[0]
                    findings.append(
                        _finding(
                            "duplicate-twin-target", path, 1,
                            f"{kind} target {key} appears in {count} {pair_name} entries",
                            f"{pair_name}|{side}|{key}",
                        )
                    )
            for key in sorted(set(paired_keys) & set(unpaired_keys)):
                path = key.split("::", 1)[0]
                findings.append(
                    _finding(
                        "twin-map-overlap", path, 1,
                        f"{kind} {key} is both paired and explicitly unpaired",
                        f"{kind}|{side}|{key}",
                    )
                )
            for key in sorted(set(paired_keys) | set(unpaired_keys)):
                if key not in inventory:
                    path = key.split("::", 1)[0]
                    findings.append(
                        _finding(
                            f"stale-twin-{kind}", path, 1,
                            f"{kind} key {key} does not resolve exactly in the current inventory",
                            f"{side}|{key}",
                        )
                    )
    return findings


def _mapped_sets(twin_map: dict) -> tuple[set[str], set[str], set[str]]:
    files: set[str] = set()
    functions: set[str] = set()
    properties: set[str] = set()
    for entry in twin_map.get("file_pairs", []):
        files.update((entry["swift"], entry["kotlin"]))
    unpaired_files = twin_map.get("unpaired_files", {})
    if isinstance(unpaired_files, dict):
        files.update(unpaired_files.get("swift", []))
        files.update(unpaired_files.get("kotlin", []))
    for entry in twin_map.get("function_pairs", []):
        functions.update((entry["swift"], entry["kotlin"]))
    unpaired_functions = twin_map.get("unpaired_functions", {})
    if isinstance(unpaired_functions, dict):
        functions.update(unpaired_functions.get("swift", []))
        functions.update(unpaired_functions.get("kotlin", []))
    for entry in twin_map.get("property_pairs", []):
        properties.update((entry["swift"], entry["kotlin"]))
    unpaired_properties = twin_map.get("unpaired_properties", {})
    if isinstance(unpaired_properties, dict):
        properties.update(unpaired_properties.get("swift", []))
        properties.update(unpaired_properties.get("kotlin", []))
    return files, functions, properties


def _bootstrap_unpaired_debts(
    identities: set[str],
    twin_map: dict,
    swift_functions: list[Declaration],
    kotlin_functions: list[Declaration],
) -> set[str]:
    declarations = {
        "swift": {item.key: item for item in swift_functions},
        "kotlin": {item.key: item for item in kotlin_functions},
    }
    unpaired = {
        language: set(twin_map.get("unpaired_functions", {}).get(language, []))
        for language in ("swift", "kotlin")
    }
    debts: set[str] = set()
    for identity in identities:
        if not isinstance(identity, str) or "\0" not in identity:
            continue
        language, key = identity.split("\0", 1)
        opposite = "kotlin" if language == "swift" else "swift"
        declaration = declarations.get(language, {}).get(key)
        if declaration is None or key not in unpaired.get(language, set()):
            continue
        counterparts = [
            item for item in declarations[opposite].values()
            if _normal_name(item.name) == _normal_name(declaration.name)
            and _normal_name(item.owner) == _normal_name(declaration.owner)
        ]
        if not counterparts:
            debts.add(identity)
    return debts


def bootstrap_unpaired_debts(root: Path, identities: set[str]) -> set[str]:
    """Independently derive reviewed existing declaration debt without comment reliance."""
    inventory = _inventory(root.resolve())
    return _bootstrap_unpaired_debts(
        identities,
        build_twin_map(root, inventory),
        inventory[2],
        inventory[3],
    )


def _call_sites(
    root: Path,
    globs: tuple[str, ...],
    errors: list[ScanError],
    snapshot: _SourceSnapshot | None = None,
) -> dict[str, list[CallSite]]:
    snapshot = snapshot or _SourceSnapshot()
    calls: dict[str, list[CallSite]] = {"swift": [], "kotlin": []}
    for path in _paths(root, globs):
        language = "swift" if path.suffix == ".swift" else "kotlin"
        text = snapshot.text(path)
        try:
            masked = snapshot.masked(path, kotlin_templates=language == "kotlin")
        except _MalformedKotlinTemplate as error:
            errors.append(
                ScanError(
                    "malformed-kotlin-template",
                    _relative(root, path),
                    text.count("\n", 0, error.offset) + 1,
                    str(error),
                )
            )
            continue
        declarations = snapshot.functions(root, path, language)
        declaration_openings = {item.opening for item in declarations}
        spans = _type_spans(masked, language)
        fallback_owner = path.stem.replace("+Trace", "Trace")
        for match in re.finditer(r"\b(`?[A-Za-z_][A-Za-z0-9_]*`?)\s*\(", masked):
            opening = match.end() - 1
            if opening in declaration_openings:
                continue
            arity = _arity(masked, opening)
            if arity is None:
                continue
            prefix = masked[max(0, match.start() - 100) : match.start()]
            receiver_match = re.search(r"(`?[A-Za-z_][A-Za-z0-9_]*`?)\s*\.\s*$", prefix)
            lexical_owner = _owner_at(spans, match.start(), fallback_owner)
            owner = receiver_match.group(1).strip("`") if receiver_match else None
            if owner in {"self", "this", "Self"}:
                owner = lexical_owner
            elif owner is not None and owner[:1].islower():
                # `burst.codesWithTimes(...)`: the receiver is an instance variable; its
                # type is not recoverable lexically, so resolve like an unqualified call.
                owner = None
            calls[language].append(
                CallSite(match.group(1).strip("`"), arity, owner, _relative(root, path), lexical_owner)
            )
    return calls


def _declaration_call_counts(
    declarations: list[Declaration], sites: dict[str, list[CallSite]]
) -> dict[str, int]:
    by_name: dict[tuple[str, str], list[Declaration]] = defaultdict(list)
    for declaration in declarations:
        by_name[(declaration.language, _normal_name(declaration.name))].append(declaration)
    counts: Counter[str] = Counter()
    for language, language_sites in sites.items():
        for site in language_sites:
            # A call may omit defaulted parameters, so besides exact-arity declarations it
            # can target any same-name declaration with MORE parameters (false test-only
            # finding for HrvAnalyzer.rollingRmssd/4: its only production call leaves
            # minBeatsPerWindow defaulted). Exact-arity candidates win outright so that the
            # relaxed pool cannot introduce owner ambiguity where none existed before.
            named = by_name.get((language, _normal_name(site.name)), [])
            exact = [item for item in named if item.arity == site.arity]
            relaxed = [
                item for item in named
                if item.required_arity <= site.arity < item.arity
            ]

            def _owner_filtered(pool: list[Declaration]) -> list[Declaration]:
                if site.owner:
                    owner = _normal_name(site.owner)
                    return [
                        item
                        for item in pool
                        if owner in {_normal_name(item.owner), _normal_name(Path(item.path).stem)}
                    ]
                # Unqualified call: same-file declarations first (self-scope calls) —
                # within the file, prefer the type whose span the call sits in, so three
                # same-named members of sibling types don't all take credit. Then the
                # global pool, only when its owner is unambiguous.
                local = [item for item in pool if item.path == site.path]
                if local:
                    if site.lexical_owner:
                        lexical = _normal_name(site.lexical_owner)
                        scoped = [item for item in local if _normal_name(item.owner) == lexical]
                        if scoped:
                            return scoped
                    return local
                owners = {_normal_name(item.owner) for item in pool}
                return pool if len(owners) == 1 else []

            candidates = _owner_filtered(exact) or _owner_filtered(relaxed)
            for candidate in candidates:
                counts[candidate.key] += 1
    return dict(counts)


def scan(root: Path, twin_map: dict) -> ScanResult:
    root = root.resolve()
    snapshot = _SourceSnapshot()
    compact_exemptions = twin_map.get("exemptions", [])
    accepted_missing_claimants = {
        item.get("identity")
        for item in compact_exemptions
        if isinstance(item, dict) and item.get("kind") == "bootstrap-unpaired-function"
    }
    try:
        inventory = _inventory(root, snapshot)
        if twin_map.get("schema_version") == 3:
            expanded = build_twin_map(root, inventory, snapshot)
            semantic_sets = semantic_authority(
                root, expanded=expanded, inventory=inventory, snapshot=snapshot
            )
            current = authority_manifest(semantic_sets)
            checked = twin_map.get("authority", {})
            authority_drift = [
                key for key in SEMANTIC_AUTHORITY_SETS
                if not isinstance(checked, dict) or checked.get(key) != current[key]
            ]
            twin_map = expanded
        else:
            authority_drift = []
            semantic_sets = {}
        (
            sw_files,
            kt_files,
            sw_funcs,
            kt_funcs,
            sw_properties,
            kt_properties,
            sw_consts,
            kt_consts,
        ) = inventory
        reference_files, all_reference_declarations = _reference_declarations(
            root, (sw_funcs, kt_funcs, sw_properties, kt_properties), snapshot
        )
        repo_sw_funcs = [item for item in all_reference_declarations if item.language == "swift" and item.kind == "function"]
        repo_kt_funcs = [item for item in all_reference_declarations if item.language == "kotlin" and item.kind == "function"]
    except _InvalidSourceEncoding as error:
        return ScanResult(
            [], {}, {},
            [ScanError("invalid-utf8", _relative(root, error.path), 1, str(error))],
            set(), set(),
        )
    findings: list[Finding] = [
        _finding(
            "twin-map-authority-drift",
            DEFAULT_MAP.relative_to(ROOT).as_posix(),
            1,
            f"derived twin-map authority changed in {section}",
            section,
        )
        for section in authority_drift
    ]
    if "unpaired_functions" in authority_drift:
        findings.extend(
            _new_unpaired_diagnostics(root, semantic_sets, [*sw_funcs, *kt_funcs])
        )
    errors: list[ScanError] = []
    findings.extend(
        _twin_map_consistency_findings(
            twin_map,
            files={_relative(root, path) for path in reference_files},
            functions={item.key for item in all_reference_declarations if item.kind == "function"},
            properties={item.key for item in all_reference_declarations if item.kind == "property"},
        )
    )
    mapped_files, mapped_functions, mapped_properties = _mapped_sets(twin_map)
    bootstrap_unpaired_debts = _bootstrap_unpaired_debts(
        accepted_missing_claimants, twin_map, sw_funcs, kt_funcs
    )

    source_refs = (
        parse_twin_references(root, sw_files, "swift", sw_funcs, snapshot)
        + parse_twin_references(root, kt_files, "kotlin", kt_funcs, snapshot)
    )
    source_resolutions = attached_function_resolutions(
        source_refs, repo_sw_funcs, repo_kt_funcs
    )
    missing_attached_claimants = {
        f"{reference.language}\0{reference.attached_function}"
        for reference, candidates in source_resolutions.items()
        if not candidates and reference.attached_function is not None
    }
    declared_pair_claims = resolved_attached_function_pairs(
        source_refs,
        repo_sw_funcs,
        repo_kt_funcs,
        resolutions=source_resolutions,
    )
    declared_pairs = set(declared_pair_claims)
    mapped_function_pairs = {
        (entry["swift"], entry["kotlin"])
        for entry in twin_map.get("function_pairs", [])
        if isinstance(entry, dict)
        and isinstance(entry.get("swift"), str)
        and isinstance(entry.get("kotlin"), str)
    }
    for reference, candidates in source_resolutions.items():
        if len(candidates) == 1:
            continue
        claimant = f"{reference.language}\0{reference.attached_function}"
        if not candidates and claimant in accepted_missing_claimants:
            continue
        candidate_keys = tuple(item.key for item in candidates)
        targets = repo_kt_funcs if reference.language == "swift" else repo_sw_funcs
        if not candidates:
            rule = "unresolved-attached-function-claim"
            detail = "does not resolve to an inventory function"
        else:
            rule = "ambiguous-attached-function-claim"
            detail = f"resolves to {len(candidates)} inventory functions: {', '.join(candidate_keys)}"
        findings.append(
            _finding(
                rule,
                reference.path,
                reference.line,
                f"attached twin claim {reference.raw_target} {detail}",
                (
                    f"{reference.path}|{reference.raw_target}|"
                    f"{reference.attached_function}|{reference.claim_ordinal}|"
                    f"{'|'.join(candidate_keys)}"
                ),
            )
        )
    for identity in sorted(accepted_missing_claimants - bootstrap_unpaired_debts):
        findings.append(
            _finding(
                "stale-bootstrap-exemption",
                identity.split("\0", 1)[-1].split("::", 1)[0],
                1,
                f"bootstrap unpaired-function exemption no longer matches a declaration without a counterpart: {identity}",
                identity,
            )
        )
    for swift_key, kotlin_key in sorted(declared_pairs - mapped_function_pairs):
        claim = declared_pair_claims[(swift_key, kotlin_key)][0]
        findings.append(
            _finding(
                "unmapped-declared-function-pair",
                claim.path,
                claim.line,
                f"attached twin claim {swift_key} -> {kotlin_key} is absent from the twin map",
                f"{swift_key}|{kotlin_key}",
            )
        )
    for swift_key, kotlin_key in sorted(mapped_function_pairs - declared_pairs):
        findings.append(
            _finding(
                "stale-declared-function-pair",
                swift_key.split("::", 1)[0],
                1,
                f"mapped function pair {swift_key} -> {kotlin_key} has no resolved attached source claim",
                f"{swift_key}|{kotlin_key}",
            )
        )

    declared_file_pairs = resolved_file_pairs(
        declared_pairs, repo_sw_funcs, repo_kt_funcs
    )
    checked_file_pairs = {
        (entry["swift"], entry["kotlin"])
        for entry in twin_map.get("file_pairs", [])
        if isinstance(entry, dict)
        and isinstance(entry.get("swift"), str)
        and isinstance(entry.get("kotlin"), str)
    }
    for swift_path, kotlin_path in sorted(declared_file_pairs - checked_file_pairs):
        findings.append(
            _finding(
                "unmapped-declared-file-pair",
                swift_path,
                1,
                f"source-declared file pair {swift_path} -> {kotlin_path} is absent from the twin map",
                f"{swift_path}|{kotlin_path}",
            )
        )
    for swift_path, kotlin_path in sorted(checked_file_pairs - declared_file_pairs):
        findings.append(
            _finding(
                "stale-declared-file-pair",
                swift_path,
                1,
                f"mapped file pair {swift_path} -> {kotlin_path} has no resolved source function claim",
                f"{swift_path}|{kotlin_path}",
            )
        )

    for language, files in (("Swift", sw_files), ("Kotlin", kt_files)):
        for path in files:
            rel = _relative(root, path)
            if rel not in mapped_files:
                findings.append(_finding("unmapped-file", rel, 1, f"new {language} file has no twin-map entry", rel))
    for declaration in sw_funcs + kt_funcs:
        if declaration.key not in mapped_functions:
            findings.append(
                _finding(
                    "unmapped-function",
                    declaration.path,
                    declaration.line,
                    f"{declaration.name}/{declaration.arity} has no twin-map entry",
                    declaration.key,
                )
            )
    for declaration in sw_properties + kt_properties:
        if declaration.key not in mapped_properties:
            findings.append(
                _finding(
                    "unmapped-property",
                    declaration.path,
                    declaration.line,
                    f"{declaration.owner}.{declaration.name} has no twin-map entry",
                    declaration.key,
                )
            )

    all_production_files = _paths(root, PRODUCTION_GLOBS)
    all_functions: list[Declaration] = []
    all_properties: list[Declaration] = []
    for path in all_production_files:
        language = "swift" if path.suffix == ".swift" else "kotlin"
        all_functions.extend(snapshot.functions(root, path, language))
        all_properties.extend(snapshot.properties(root, path, language))
    all_swift_files = [path for path in reference_files if path.suffix == ".swift"]
    all_kotlin_files = [path for path in reference_files if path.suffix == ".kt"]
    all_swift_functions = [item for item in all_functions if item.language == "swift"]
    all_kotlin_functions = [item for item in all_functions if item.language == "kotlin"]

    reference_swift_declarations = [item for item in all_reference_declarations if item.language == "swift"]
    reference_kotlin_declarations = [item for item in all_reference_declarations if item.language == "kotlin"]
    refs = parse_twin_references(root, all_swift_files, "swift", reference_swift_declarations, snapshot) + parse_twin_references(
        root,
        all_kotlin_files,
        "kotlin",
        reference_kotlin_declarations,
        snapshot,
    )
    swift_symbols = _symbol_owners(
        root,
        all_swift_files,
        reference_swift_declarations,
        snapshot,
    )
    kotlin_symbols = _symbol_owners(
        root,
        all_kotlin_files,
        reference_kotlin_declarations,
        snapshot,
    )
    resolved_refs = 0
    for reference in refs:
        target_symbols = kotlin_symbols if reference.language == "swift" else swift_symbols
        if _reference_resolves(reference, target_symbols):
            resolved_refs += 1
            continue
        claimant = (
            f"{reference.language}\0{reference.attached_function}"
            if reference.attached_function is not None else None
        )
        if claimant in accepted_missing_claimants:
            continue
        target_language = "Kotlin" if reference.language == "swift" else "Swift"
        findings.append(
            _finding(
                "dead-twin-reference",
                reference.path,
                reference.line,
                f"{target_language} target {reference.raw_target} does not resolve",
                (
                    f"{reference.path}|{reference.raw_target}|"
                    f"{reference.attached_function or '<file>'}|{reference.claim_ordinal}"
                ),
            )
        )

    constants_by_key = {item.key: item for item in sw_consts + kt_consts}
    paired_constants, ambiguous_constants = _constant_pairing(
        sw_consts, kt_consts, declared_file_pairs
    )
    dynamic_pairs = {(left.key, right.key) for left, right in paired_constants}
    mapped_pairs = {(entry["swift"], entry["kotlin"]) for entry in twin_map.get("constant_pairs", [])}
    for left_key, right_key in sorted(dynamic_pairs - mapped_pairs):
        left = constants_by_key[left_key]
        right = constants_by_key[right_key]
        findings.append(
            _finding(
                "unmapped-constant-pair",
                left.path,
                left.line,
                f"mirrored constant pair {left_key} -> {right_key} is absent from the twin map",
                f"{left_key}|{right_key}",
            )
        )
    for left_key, right_key in sorted(dynamic_pairs | mapped_pairs):
        left = constants_by_key.get(left_key)
        right = constants_by_key.get(right_key)
        if left is None or right is None:
            if (left_key, right_key) in mapped_pairs:
                present = left or right
                missing = left_key if left is None else right_key
                findings.append(
                    _finding(
                        "stale-constant-pair",
                        present.path if present is not None else left_key.split("::", 1)[0],
                        present.line if present is not None else 1,
                        f"mapped constant {missing} does not resolve",
                        f"{left_key}|{right_key}",
                    )
                )
            continue
        if left.value is None or right.value is None:
            findings.append(
                _finding(
                    "constant-unverifiable",
                    left.path,
                    left.line,
                    f"cannot fully evaluate {left.name}={left.display_value} against Kotlin {right.name}={right.display_value} ({right.path}:{right.line})",
                    f"{left_key}|{left.display_value}|{right_key}|{right.display_value}",
                )
            )
            continue
        if left.value == right.value:
            continue
        findings.append(
            _finding(
                "constant-value-mismatch",
                left.path,
                left.line,
                f"{left.name}={left.display_value} differs from Kotlin {right.name}={right.display_value} ({right.path}:{right.line})",
                f"{left_key}|{left.value}|{right_key}|{right.value}",
            )
        )

    for normal_name, left, right in ambiguous_constants:
        left_keys = ", ".join(item.key for item in left)
        right_keys = ", ".join(item.key for item in right)
        first = left[0]
        findings.append(
            _finding(
                "constant-ambiguous",
                first.path,
                first.line,
                f"{normal_name} cannot be paired uniquely: Swift [{left_keys}] vs Kotlin [{right_keys}]",
                f"{normal_name}|{'|'.join(item.key for item in left)}|{'|'.join(item.key for item in right)}",
            )
        )

    inventory_functions = sw_funcs + kt_funcs
    prod_calls = _declaration_call_counts(
        inventory_functions, _call_sites(root, PRODUCTION_GLOBS, errors, snapshot)
    )
    test_calls = _declaration_call_counts(
        inventory_functions, _call_sites(root, TEST_GLOBS, errors, snapshot)
    )
    for declaration in sw_funcs + kt_funcs:
        if test_calls.get(declaration.key, 0) > 0 and prod_calls.get(declaration.key, 0) == 0:
            findings.append(
                _finding(
                    "test-only-callsite",
                    declaration.path,
                    declaration.line,
                    f"{declaration.owner}.{declaration.name}/{declaration.arity} has {test_calls[declaration.key]} test callsite(s) and no production callsite",
                    declaration.key,
                )
            )

    day_string = [item for item in all_functions if item.name == "dayString"]
    ui_pearson = [
        item for item in all_functions
        if item.language == "kotlin" and item.name == "pearson" and item.path.startswith("android/app/src/main/java/com/noop/ui/")
    ]
    resting = [item for item in sw_funcs + kt_funcs if item.name in {"restingHR", "sessionRestingHR"}]
    for declaration in day_string:
        findings.append(
            _finding(
                "duplicate-implementation",
                declaration.path,
                declaration.line,
                f"dayString implementation {declaration.owner}.{declaration.name}/{declaration.arity}",
                f"dayString|{declaration.key}",
            )
        )
    for declaration in ui_pearson:
        findings.append(
            _finding(
                "duplicate-implementation",
                declaration.path,
                declaration.line,
                f"independent Android UI Pearson implementation {declaration.owner}.pearson/{declaration.arity}",
                f"android-ui-pearson|{declaration.key}",
            )
        )
    for declaration in resting:
        findings.append(
            _finding(
                "duplicate-implementation",
                declaration.path,
                declaration.line,
                f"resting-HR path {declaration.owner}.{declaration.name}/{declaration.arity}",
                f"resting-hr|{declaration.key}",
            )
        )

    findings.sort(key=lambda item: (item.path, item.line, item.rule, item.identity))
    counters = {
        "day_string_implementations": len(day_string),
        "resting_hr_paths": len({item.name for item in resting}),
        "android_ui_pearson_implementations": len(ui_pearson),
    }
    stats = {
        "swift_files": len(sw_files),
        "kotlin_files": len(kt_files),
        "swift_functions": len(sw_funcs),
        "kotlin_functions": len(kt_funcs),
        "swift_properties": len(sw_properties),
        "kotlin_properties": len(kt_properties),
        "swift_constants": len(sw_consts),
        "kotlin_constants": len(kt_consts),
        "swift_parity_annotations": _annotation_count(sw_files, snapshot),
        "kotlin_parity_annotations": _annotation_count(kt_files, snapshot),
        "declared_twin_references": len(refs),
        "resolved_twin_references": resolved_refs,
        "constant_pairs": len(dynamic_pairs | mapped_pairs),
    }
    errors.extend(
        ScanError(item.rule, item.path, item.line, item.text)
        for item in findings
        if item.rule in HARD_FINDING_RULES
    )
    errors = sorted(
        set(errors),
        key=lambda item: (item.path, item.line, item.rule, item.text),
    )
    return ScanResult(
        findings, counters, stats, errors, missing_attached_claimants,
        bootstrap_unpaired_debts,
    )


def _load_json(path: Path, default: dict) -> dict:
    if not path.exists():
        return default
    value = json.loads(path.read_text())
    issue_ref.validate_current_issue_fields(value, str(path))
    return value


def _write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if value.get("schema_version") == 3:
        def render(node: object, level: int = 0) -> list[str]:
            pad = "  " * level
            if isinstance(node, dict):
                if node and all(not isinstance(child, (dict, list)) for child in node.values()):
                    return [pad + json.dumps(node, ensure_ascii=False, separators=(", ", ": "))]
                lines = [pad + "{"]
                items = list(node.items())
                for index, (key, child) in enumerate(items):
                    rendered = render(child, level + 1)
                    prefix = "  " * (level + 1) + json.dumps(key) + ": "
                    rendered[0] = prefix + rendered[0].lstrip()
                    if index + 1 < len(items):
                        rendered[-1] += ","
                    lines.extend(rendered)
                lines.append(pad + "}")
                return lines
            if isinstance(node, list):
                if not node:
                    return [pad + "[]"]
                lines = [pad + "["]
                for index, child in enumerate(node):
                    rendered = render(child, level + 1)
                    if index + 1 < len(node):
                        rendered[-1] += ","
                    lines.extend(rendered)
                lines.append(pad + "]")
                return lines
            return [pad + json.dumps(node, ensure_ascii=False)]

        path.write_text("\n".join(render(value)) + "\n", encoding="utf-8")
    else:
        path.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def _publish_json_pair(first_path: Path, first: dict, second_path: Path, second: dict) -> None:
    """Publish two JSON snapshots as one rollback-safe operation."""
    paths = (first_path, second_path)
    values = (first, second)
    old = [(path.exists(), path.read_bytes() if path.exists() else b"") for path in paths]
    temporary: list[Path] = []
    try:
        for path, value in zip(paths, values):
            path.parent.mkdir(parents=True, exist_ok=True)
            descriptor, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
            os.close(descriptor)
            candidate = Path(name)
            temporary.append(candidate)
            _write_json(candidate, value)
        os.replace(temporary[0], first_path)
        temporary.pop(0)
        os.replace(temporary[0], second_path)
        temporary.pop(0)
    except BaseException:
        for path, (existed, content) in zip(paths, old):
            if existed:
                descriptor, name = tempfile.mkstemp(prefix=f".{path.name}.rollback.", dir=path.parent)
                try:
                    with os.fdopen(descriptor, "wb") as handle:
                        handle.write(content)
                    os.replace(name, path)
                finally:
                    Path(name).unlink(missing_ok=True)
            else:
                path.unlink(missing_ok=True)
        raise
    finally:
        for path in temporary:
            path.unlink(missing_ok=True)


BASELINE_REASONS = {
    "test-only-callsite": "Exact declaration is reached only from tests in the conservative lexical call graph; dynamic, callback and external entry points are intentionally not inferred.",
    "duplicate-implementation": "Exact platform-local implementation is retained as visible parity debt pending a source-level consolidation decision.",
    "constant-unverifiable": "Exact mirrored constant uses a lexical expression that the standard-library scanner cannot evaluate safely.",
    "constant-value-mismatch": "Exact mirrored constant values differ on current upstream and remain visible as parity debt.",
    "constant-ambiguous": "Exact normalized constant name has multiple viable cross-language matches and remains visible until explicitly disambiguated.",
}


def _finding_domain(path: str) -> str:
    pieces = path.split("/")
    if path.startswith("android/app/src/main/java/com/noop/") and len(pieces) > 7:
        return f"android/{pieces[7]}"
    if path.startswith("Packages/") and len(pieces) > 1:
        return f"Packages/{pieces[1]}"
    return pieces[0]


def baseline_group_provenance(rule: str, scope: str) -> str:
    return (
        f"Exact identities emitted by parity_ledger rule {rule} "
        f"for current upstream scope {scope}; no wildcard matching."
    )


def build_compact_baseline(result: ScanResult) -> dict:
    """Group exact accepted identities while retaining narrow review provenance."""
    grouped: dict[tuple[str, str], list[str]] = defaultdict(list)
    for finding in result.findings:
        if finding.rule in HARD_FINDING_RULES:
            continue
        if finding.rule not in BASELINE_REASONS:
            raise ValueError(
                f"finding {finding.identity} has no reviewed compact-baseline disposition"
            )
        grouped[(finding.rule, _finding_domain(finding.path))].append(finding.identity)
    return {
        "schema_version": 3,
        "accepted_findings": [
            {
                "rule": rule,
                "scope": domain,
                "reason": BASELINE_REASONS[rule],
                "provenance": baseline_group_provenance(rule, domain),
                "count": len(identities),
                "identities_sha256": _canonical_sha256(sorted(identities)),
            }
            for (rule, domain), identities in sorted(grouped.items())
        ],
        "counters": result.counters,
    }


def compact_baseline_drift(result: ScanResult, baseline: dict) -> list[str]:
    try:
        current = build_compact_baseline(result)
    except ValueError as exc:
        return [str(exc)]
    checked_groups = {
        (item.get("rule"), item.get("scope")): item
        for item in baseline.get("accepted_findings", [])
        if isinstance(item, dict)
    }
    current_groups = {
        (item["rule"], item["scope"]): item
        for item in current["accepted_findings"]
    }
    return [
        f"{rule}|{scope}"
        for rule, scope in sorted(set(checked_groups) | set(current_groups))
        if checked_groups.get((rule, scope), {}).get("count")
        != current_groups.get((rule, scope), {}).get("count")
        or checked_groups.get((rule, scope), {}).get("identities_sha256")
        != current_groups.get((rule, scope), {}).get("identities_sha256")
    ]


def compact_baseline_changes(
    result: ScanResult, baseline: dict
) -> tuple[list[str], list[str]]:
    """Return (regressions, improvements) for compact finding groups."""
    try:
        current = build_compact_baseline(result)
    except ValueError as exc:
        return [str(exc)], []
    checked_groups = {
        (item.get("rule"), item.get("scope")): item
        for item in baseline.get("accepted_findings", [])
        if isinstance(item, dict)
    }
    current_groups = {
        (item["rule"], item["scope"]): item
        for item in current["accepted_findings"]
    }
    regressions: list[str] = []
    improvements: list[str] = []
    for key in sorted(set(checked_groups) | set(current_groups)):
        old = checked_groups.get(key)
        new = current_groups.get(key)
        label = f"{key[0]}|{key[1]}"
        if old is None:
            regressions.append(label)
        elif new is None or new["count"] < old.get("count", 0):
            improvements.append(label)
        elif (new["count"] > old.get("count", 0)
              or new["identities_sha256"] != old.get("identities_sha256")):
            regressions.append(label)
    return regressions, improvements


def finding_identities_at_git_ref(root: Path, ref: str) -> set[str]:
    """Independently scan an exact git tree for monotonic baseline proof."""
    try:
        resolved = subprocess.check_output(
            ["git", "rev-parse", "--verify", f"{ref}^{{commit}}"],
            cwd=root,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", resolved) is None:
            raise ValueError(f"git returned an invalid commit for base {ref!r}")
        archive = subprocess.check_output(
            ["git", "archive", "--format=tar", resolved], cwd=root
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        raise ValueError(f"cannot scan exact base {ref!r}") from exc
    with tempfile.TemporaryDirectory() as directory:
        base_root = Path(directory)
        try:
            with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as bundle:
                bundle.extractall(base_root, filter="data")
        except (tarfile.TarError, TypeError) as exc:
            raise ValueError(f"cannot materialize exact base {ref!r}") from exc
        base_map = build_compact_twin_map(base_root)
        base_result = scan(base_root, base_map)
        if base_result.errors:
            raise ValueError(f"cannot prove improvement against invalid base {ref!r}")
        return {finding.identity for finding in base_result.findings}


def _summary(result: ScanResult) -> str:
    stats = result.stats
    return (
        f"{stats['swift_files']} Swift files, {stats['kotlin_files']} Kotlin files; "
        f"{stats['swift_functions']} Swift functions, {stats['kotlin_functions']} Kotlin functions; "
        f"{stats['swift_properties']} Swift properties, {stats['kotlin_properties']} Kotlin properties; "
        f"{stats['swift_constants']} Swift constants, {stats['kotlin_constants']} Kotlin constants; "
        f"annotations Swift={stats['swift_parity_annotations']}, Kotlin={stats['kotlin_parity_annotations']}; "
        f"{stats['declared_twin_references']} declared twin references "
        f"({stats['resolved_twin_references']} resolved); {stats['constant_pairs']} constant pairs; "
        f"counters dayString={result.counters['day_string_implementations']}, "
        f"resting-HR={result.counters['resting_hr_paths']}, "
        f"Android-UI-Pearson={result.counters['android_ui_pearson_implementations']}"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root")
    parser.add_argument("--map", dest="map_path", type=Path, help="twin-map JSON path")
    parser.add_argument("--baseline", dest="baseline_path", type=Path, help="baseline JSON path")
    parser.add_argument("--no-baseline", action="store_true", help="show every current finding")
    parser.add_argument("--bootstrap-map", action="store_true", help="write a fresh inventory map before scanning")
    parser.add_argument("--write-baseline", action="store_true", help="rewrite the baseline with current findings")
    parser.add_argument("--refresh-derived", action="store_true", help="refresh existing derived snapshots only if the ratchet accepts the result")
    parser.add_argument("--base", default="origin/main", help="exact git ref used to prove debt reductions")
    args = parser.parse_args(argv)

    root = args.root.resolve()
    map_path = args.map_path or root / "Tools/parity_twin_map.json"
    baseline_path = args.baseline_path or root / "Tools/parity_ledger_baseline.json"
    if args.bootstrap_map != args.write_baseline:
        print("FAIL --bootstrap-map and --write-baseline must be used together")
        return 2
    if args.refresh_derived:
        if args.bootstrap_map or args.write_baseline or args.no_baseline:
            print("FAIL --refresh-derived cannot be combined with bootstrap, baseline, or display modes")
            return 2
        if not map_path.exists() or not baseline_path.exists():
            print("FAIL --refresh-derived requires existing authority; use --bootstrap-map --write-baseline once")
            return 2
        if args.map_path is not None or args.baseline_path is not None:
            print("FAIL --refresh-derived only supports the canonical checked-in snapshot paths")
            return 2
        old_map = map_path.read_bytes()
        old_baseline = baseline_path.read_bytes()
        candidate_map = build_compact_twin_map(root)
        candidate_result = scan(root, candidate_map)
        if candidate_result.errors:
            print(f"FAIL {len(candidate_result.errors)} parity ledger scan error(s); snapshots unchanged")
            return 1
        accepted = False
        try:
            _write_json(map_path, candidate_map)
            _write_json(baseline_path, build_compact_baseline(candidate_result))
            command = [
                sys.executable, str(Path(__file__).with_name("parity_ratchet.py")),
                "--root", str(root), "--base", args.base, "--offline",
            ]
            completed = subprocess.run(command, cwd=root, text=True, capture_output=True)
            if completed.returncode:
                print("FAIL derived refresh rejected; snapshots restored")
                print((completed.stderr or completed.stdout).strip())
                return 1
            accepted = True
        finally:
            if not accepted:
                map_path.write_bytes(old_map)
                baseline_path.write_bytes(old_baseline)
        print(f"WROTE reviewed derived snapshots ({len(candidate_result.findings)} known findings)")
        return 0
    if args.bootstrap_map:
        if map_path.exists() or baseline_path.exists():
            print("FAIL --bootstrap-map is for initial authority creation only; use the reviewed refresh workflow for existing authority")
            return 2
        twin_map = build_compact_twin_map(root)
        result = scan(root, twin_map)
        if result.errors:
            print(f"FAIL {len(result.errors)} parity ledger scan error(s); snapshots unchanged")
            for error in result.errors:
                print(f"  {error.output()}")
            return 1
        baseline = build_compact_baseline(result)
        _publish_json_pair(map_path, twin_map, baseline_path, baseline)
        expanded, drift = expand_twin_map(root, twin_map)
        assert not drift
        print(f"WROTE {map_path} and {baseline_path} ({len(expanded['function_pairs'])} derived function pairs; {len(result.findings)} known findings)")
        return 0
    else:
        twin_map = _load_json(map_path, {})

    result = scan(root, twin_map)
    if result.errors:
        print(f"FAIL {len(result.errors)} parity ledger scan error(s):\n")
        for error in result.errors:
            print(f"  {error.output()}")
        noun = "error" if len(result.errors) == 1 else "errors"
        print(f"\nBaseline not evaluated: {len(result.errors)} scan {noun}.")
        return 1
    if args.no_baseline:
        if result.findings:
            print(f"FAIL {len(result.findings)} current parity ledger finding(s):\n")
            for item in result.findings:
                print(f"  {item.output()}")
            print(f"\nScanned {_summary(result)}")
            return 1
        print(f"OK no parity ledger findings ({_summary(result)})")
        return 0

    baseline = _load_json(baseline_path, {})
    compact_drift, improvements = compact_baseline_changes(result, baseline)
    baseline_counters = baseline.get("counters", {})
    counter_regressions = [
        (name, baseline_counters[name], count)
        for name, count in result.counters.items()
        if name in baseline_counters and count > baseline_counters[name]
    ]
    if compact_drift:
        print(f"FAIL compact baseline drift in {', '.join(compact_drift)}")
        actionable = [item for item in result.findings if item.rule.startswith("add-unpaired-")]
        if actionable:
            print("\nActionable source drift:")
            for item in actionable:
                print(f"  {item.output()}")
        print(f"\nScanned {_summary(result)}")
        return 1

    if improvements:
        try:
            base_identities = finding_identities_at_git_ref(root, args.base)
        except ValueError as exc:
            print(f"FAIL {exc}; cannot prove that compact baseline drift is only a decrease")
            return 1
        new_identities = {
            item.identity for item in result.findings
        } - base_identities
        if new_identities:
            print("FAIL debt count decreased but replacement findings are new against the exact base:")
            for identity in sorted(new_identities):
                print(f"  {identity}")
            return 1
        for improvement in improvements:
            print(f"WARNING debt decreased in {improvement}; baseline cleanup is optional")

    if counter_regressions:
        total = len(counter_regressions)
        print(f"FAIL {total} parity ledger finding(s) beyond the baseline:\n")
        for name, was, now in counter_regressions:
            print(f"  {baseline_path.relative_to(root)}:1: duplicate-counter: {name} increased from {was} to {now}")
        print(f"\nScanned {_summary(result)}")
        return 1

    print(f"OK no NEW parity ledger findings ({len(result.findings)} baselined; {_summary(result)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
