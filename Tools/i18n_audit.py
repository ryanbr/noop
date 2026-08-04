#!/usr/bin/env python3
"""Audit user-facing text for translation gaps across both platforms.

Two independent problems, both covered here:

1. Hardcoded literals — a `Text("Charge")`-style call that never goes through
   any localization mechanism at all (Kotlin has no auto-extraction like
   SwiftUI's LocalizedStringKey, so any literal in a Compose Text/title/label
   call is unlocalized by construction). Reported as HARDCODED.
2. Catalog drift — a string IS wired through localization (a SwiftUI
   LocalizedStringKey, or an Android stringResource key) but a target
   language's translation is missing from the String Catalog / strings.xml.
   Reported as MISSING_<LANG>.

Target languages: de, es, fr, pt-PT (the focus set). English is the source
language and is not checked for itself.

Read-only. Prints a report; does not modify any file. Re-runnable, and the
same logic is meant to be wired into a CI check later (see i18n-coverage.yml)
so this stops being a manual step.

Usage: python3 Tools/i18n_audit.py [--platform ios|android|all] [--full]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGS = ["de", "es", "fr", "pt-PT"]
ANDROID_LOCALE_DIRS = {
    "de": "values-de",
    "es": "values-es",
    "fr": "values-fr",
    "pt-PT": "values-pt-rPT",
}

# Strings that are legitimately identical across all languages (symbols,
# format-only placeholders, brand name, units) — mirrors the exclude
# reasoning already established in Tools/translate-de.py. Extend as needed;
# false positives here just mean noise in the report, not a wrong fix.
UNIVERSAL = {
    "", "-", "–", "—", "·", "•", "✓", "→", "↔",
    "NOOP", "bpm", "BPM", "HRV", "SpO2", "SpO₂", "OK", "ID",
}

# A bare printf/String.format conversion specifier, e.g. "%.1f" or "%02d" — a
# format string, not translatable copy. `re.search(r"[A-Za-z]", s)` alone
# can't tell these apart from real text, since the conversion character
# itself (f/d/s/...) counts as a letter.
PURE_FORMAT_SPEC = re.compile(r"^%[-+0 #,(]*\d*(?:\.\d+)?[sdifoxXeEgGcC]$")


def is_probably_ui_text(s: str) -> bool:
    """Filter out obvious non-UI-text matches (identifiers, tags, formats)."""
    if s in UNIVERSAL:
        return False
    if not re.search(r"[A-Za-z]", s):
        return False  # pure symbols/numbers/format specifiers
    if PURE_FORMAT_SPEC.fullmatch(s):
        return False
    # snake_case / dotted / slashed identifiers (testTags, routes, keys) —
    # real UI copy almost always has a space or is a capitalized single word.
    if re.fullmatch(r"[a-z][a-z0-9_./]*", s) and " " not in s:
        return False
    if s.startswith("http://") or s.startswith("https://"):
        return False
    return True


# ---------------------------------------------------------------------------
# Balanced-span scanning helpers (shared by Android and Apple below)
# ---------------------------------------------------------------------------
#
# A flat regex that requires the literal to sit immediately after the opening
# paren/`=` only sees `Text("Save")`. `Text(if (saved) "Saved" else "Save")` —
# a real, shipped shape (#540) — slides straight past: `Text(` is followed by
# `if`, not `"`. These walk the actual bracket structure instead, so a literal
# anywhere inside a call/kwarg's OWN argument expression is visible regardless
# of what control-flow construct (if/else, when, ?:, .let) puts it there —
# without also sweeping into an unrelated NESTED composable's own slot lambda
# (a `title = { Column { /* a separate, separately-scanned subtree */ } }`),
# which is a different bug (489 spurious findings, not 7) than the one this
# is fixing.


def _skip_string_literal(text: str, i: int) -> int:
    """`text[i]` is the opening `"` of a string literal; return the index just
    past its closing `"`, honoring backslash escapes AND Kotlin/Swift string-
    template interpolation (`${expr}` / `\\(expr)`), which can itself contain
    a nested string literal (e.g. the pluralization idiom
    `"${if (n == 1) "day" else "days"}"`) — a naive scan for the next `"`
    would end the OUTER literal early on the interpolated one's opening quote."""
    i += 1
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            i += 2
            continue
        if ch == "$" and i + 1 < len(text) and text[i + 1] == "{":
            i += 2
            depth = 1
            while i < len(text) and depth:
                c2 = text[i]
                if c2 == '"':
                    i = _skip_string_literal(text, i)
                    continue
                if c2 == "{":
                    depth += 1
                elif c2 == "}":
                    depth -= 1
                i += 1
            continue
        if ch == '"':
            return i + 1
        i += 1
    return i


def _argument_span_end(text: str, start: int) -> int:
    """`start` is just after a call's `(` or a kwarg's `=`; return the index
    where that single argument's expression ends — the next top-level comma,
    or the bracket that closes the enclosing call/lambda."""
    depth = 0
    i = start
    while i < len(text):
        ch = text[i]
        if ch == '"':
            i = _skip_string_literal(text, i)
            continue
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            if depth == 0:
                return i
            depth -= 1
        elif ch == "," and depth == 0:
            return i
        i += 1
    return i


_TRANSPARENT_BARE_KEYWORDS = {"else", "try", "finally", "when"}
_TRANSPARENT_PAREN_KEYWORDS = {"if", "when", "catch"}


def _word_before(text: str, end: int, limit: int) -> tuple[str, int]:
    """The identifier/keyword ending just before `end` (not before `limit`),
    and the index of its first character."""
    start = end
    while start > limit and (text[start - 1].isalnum() or text[start - 1] == "_"):
        start -= 1
    return text[start:end], start


def _brace_is_transparent(text: str, brace_idx: int, span_start: int) -> bool:
    """Should the literal-extraction walk look INSIDE `text[brace_idx]` (a
    `{`), or skip its whole balanced body untouched?

    Transparent for the Kotlin idioms that this codebase actually uses to
    conditionally pick a string: `if (...) { }`, `when (...) { }` / bare
    `when { }`, `catch (...) { }`, bare `else`/`try`/`finally`, and
    `.let { }` / `?.let { }` (used as a null-coalescing ternary substitute
    here, typically paired with `?:`). Opaque for everything else — an
    assignment's trailing lambda, a `Column { }` or other composable slot —
    because that is a SEPARATE, independently-composed subtree that the
    file-wide call/kwarg scan discovers and scans on its own when it reaches
    the calls nested inside it directly; sweeping it again from here is how
    the first cut at this fix produced 489 findings instead of a few dozen.

    Deliberately no fixed lookback window (an early draft's 60-char window
    sat exactly on the edge of a real `when (...)` subject in this codebase
    — see RhythmScreen.kt:309): walks backward through at most one balanced
    `(...)` and checks the keyword immediately behind it.
    """
    i = brace_idx - 1
    while i >= span_start and text[i].isspace():
        i -= 1
    if i < span_start:
        return False
    if text[i] == ")":
        depth = 1
        j = i - 1
        while j >= span_start and depth:
            if text[j] == ")":
                depth += 1
            elif text[j] == "(":
                depth -= 1
            j -= 1
        k = j
        while k >= span_start and text[k].isspace():
            k -= 1
        word, _ = _word_before(text, k + 1, span_start)
        return word in _TRANSPARENT_PAREN_KEYWORDS
    word, word_start = _word_before(text, i + 1, span_start)
    if word in _TRANSPARENT_BARE_KEYWORDS:
        return True
    if word == "let" and word_start > span_start and text[word_start - 1] == ".":
        return True
    return False


def _extract_literals(text: str, start: int, end: int) -> list[tuple[int, str]]:
    """(offset, content) for every literal directly reachable within
    text[start:end] — descending transparently through `(`/`[` and through
    any `{` that `_brace_is_transparent` calls a control-flow block, skipping
    the whole balanced body of any other `{` untouched. Skips a literal whose
    nearest preceding non-whitespace token is `+`: string concatenation
    (typically `uiString(R.string.x) + "hardcoded suffix"`) is a real but
    DIFFERENT, larger bug (partial localization via an engineered prefix) —
    deliberately out of scope here, tracked separately."""
    out: list[tuple[int, str]] = []
    i = start
    while i < end:
        ch = text[i]
        if ch == '"':
            j = _skip_string_literal(text, i)
            prev = i - 1
            while prev >= start and text[prev].isspace():
                prev -= 1
            if prev < start or text[prev] != "+":
                out.append((i, text[i + 1:j - 1]))
            i = j
            continue
        if ch == "{":
            if _brace_is_transparent(text, i, start):
                i += 1
                continue
            depth = 1
            i += 1
            while i < end and depth:
                c2 = text[i]
                if c2 == '"':
                    i = _skip_string_literal(text, i)
                    continue
                if c2 in "({[":
                    depth += 1
                elif c2 in ")}]":
                    depth -= 1
                i += 1
            continue
        i += 1
    return out


# ---------------------------------------------------------------------------
# Android: hardcoded Compose literals
# ---------------------------------------------------------------------------

ANDROID_DIRS = [
    ROOT / "android/app/src/main/java/com/noop/ui",
    ROOT / "android/app/src/main/java/com/noop/widget",
    ROOT / "android/app/src/main/java/com/noop/ble",
    ROOT / "android/app/src/main/java/com/noop/notif",
]

# `AlertDialog` is deliberately NOT in this list: confirmed (all 22 call sites
# in this codebase) it never takes its text as a positional argument, only as
# `title=`/`text=` kwargs — those are covered by ANDROID_KWARG_PATTERN below.
# `Snackbar(`/`TopAppBar(` do not currently appear anywhere in this codebase;
# kept for whatever future call sites use them, since `Text(` always does
# take its content as the first argument here.
ANDROID_CALL_PATTERN = re.compile(r"\b(?:Text|Snackbar|TopAppBar|setContentTitle|setContentText)\s*\(")
ANDROID_KWARG_PATTERN = re.compile(r"\b(?:title|label|text|contentDescription|placeholder)\s*=\s*")

# `contentDescription = <expr>` is UI accessibility text wherever it is ASSIGNED. Unlike the general
# kwargs it most often sits inside a `Modifier.semantics { }` lambda, whose `{` is NOT an argument
# boundary — so the kwarg pass skips it and the a11y copy stays invisible in a green audit (#571). Scan
# the assignment on its own: a bare `contentDescription =` that is not a `==` comparison, a `.member`
# read, or a `val`/`var` local declaration is a UI-text site. Only its OWN value span is read (via
# `_argument_span_end`, which stops at the enclosing `}`), so unrelated lambda content is never swept in.
ANDROID_A11Y_ASSIGN_PATTERN = re.compile(r"(?<![.\w])contentDescription\s*=(?!=)\s*")
_LOCAL_DECL_BEFORE = re.compile(r"\b(?:val|var)\s+\Z")
_SIMPLE_IDENTIFIER = re.compile(r"[A-Za-z_]\w*\Z")
_LOCAL_VAL_PATTERN = re.compile(r"\bval\s+([A-Za-z_]\w*)\s*=\s*")


def _mask_comments(text: str) -> str:
    """`text` with `//...` and `/* ... */` comment BODIES blanked out (same
    length, spaces, newlines preserved) so a quoted-looking phrase inside a
    comment can never be mistaken for a real string literal — and so a stray
    bracket inside a comment can't confuse the depth-tracking helpers above.
    String-literal-aware: a `//`/`/*` that appears inside an actual string
    isn't a comment start."""
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            i = _skip_string_literal(text, i)
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            j = i
            while j < n and text[j] != "\n":
                out[j] = " "
                j += 1
            i = j
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            j = i
            while j < n and not (text[j] == "*" and j + 1 < n and text[j + 1] == "/"):
                if text[j] != "\n":
                    out[j] = " "
                j += 1
            if j < n:
                out[j] = out[j + 1] = " "
                j += 2
            i = j
            continue
        i += 1
    return "".join(out)


def _brace_stack_at(text: str, end: int) -> tuple[int, ...]:
    """Opening `{` offsets whose scopes contain `end`, ignoring string
    contents. Used for the deliberately small bit of Kotlin name resolution
    below: a local `val` is visible only while its declaring brace is still
    open at the use site."""
    stack: list[int] = []
    i = 0
    while i < end:
        ch = text[i]
        if ch == '"':
            i = _skip_string_literal(text, i)
            continue
        if ch == "{":
            stack.append(i)
        elif ch == "}" and stack:
            stack.pop()
        i += 1
    return tuple(stack)


def _statement_span_end(text: str, start: int) -> int:
    """End of a Kotlin `val` initializer.

    Newlines before the expression are allowed; once the expression starts, a
    newline or semicolon at top level ends it unless Kotlin syntax clearly
    continues on the next line (for example `"prefix" +` followed by an
    `if`). Balanced calls and `when { }` / `if { }` expressions can span lines
    without exposing the following statements to literal extraction.
    """
    depth = 0
    saw_expression = False
    i = start
    while i < len(text):
        ch = text[i]
        if ch == '"':
            saw_expression = True
            i = _skip_string_literal(text, i)
            continue
        if ch in "({[":
            depth += 1
            saw_expression = True
        elif ch in ")}]":
            if depth == 0:
                return i
            depth -= 1
        elif depth == 0 and ch == ";":
            return i
        elif depth == 0 and ch == "\n" and saw_expression:
            previous = i - 1
            while previous >= start and text[previous].isspace():
                previous -= 1
            following = i + 1
            while following < len(text) and text[following].isspace():
                following += 1
            trails_operator = (
                previous >= start and text[previous] in "+-*/%&|?:,.="
            )
            starts_continuation = (
                text.startswith(".", following)
                or text.startswith("?:", following)
                or re.match(r"else\b", text[following:]) is not None
            )
            if not trails_operator and not starts_continuation:
                return i
        elif not ch.isspace():
            saw_expression = True
        i += 1
    return i


def _visible_val_initializer(
    text: str, name: str, use_offset: int
) -> tuple[int, int] | None:
    """Initializer span for the nearest preceding `val name = ...` visible at
    `use_offset`.

    This is intentionally lexical rather than general Kotlin dataflow. It
    covers the common Compose shape `val a11y = when { ... }; semantics {
    contentDescription = a11y }`, while declining parameters, properties
    outside a braced scope, computed references, and declarations in sibling
    blocks. The nearest visible declaration wins, matching local shadowing.
    """
    use_scopes = set(_brace_stack_at(text, use_offset))
    declarations = list(_LOCAL_VAL_PATTERN.finditer(text, 0, use_offset))
    for declaration in reversed(declarations):
        if declaration.group(1) != name:
            continue
        declaration_scopes = _brace_stack_at(text, declaration.start())
        if not declaration_scopes or declaration_scopes[-1] not in use_scopes:
            continue
        start = declaration.end()
        return start, _statement_span_end(text, start)
    return None


# Only an argument in actual call-argument position (right after `(` or `,`,
# modulo whitespace) — excludes `val text = when { "Awake" -> ...; ... }`,
# a plain local declaration this keyword list would otherwise also match.
_PRECEDED_BY_ARG_BOUNDARY = re.compile(r"[(,]\s*\Z")


def scan_android() -> list[tuple[str, int, str]]:
    findings = []
    for base in ANDROID_DIRS:
        if not base.exists():
            continue
        for path in sorted(base.rglob("*.kt")):
            raw = path.read_text(encoding="utf-8", errors="replace")
            text = _mask_comments(raw)
            seen: set[int] = set()

            def record(span_start: int, span_end: int) -> None:
                for offset, literal in _extract_literals(text, span_start, span_end):
                    if offset in seen or not is_probably_ui_text(literal):
                        continue
                    seen.add(offset)
                    line_no = text.count("\n", 0, offset) + 1
                    findings.append((str(path.relative_to(ROOT)), line_no, literal))

            # The call's own first (content) argument only — catches
            # `Text(if (x) "a" else "b")` — never the whole call span, which
            # would also sweep in an unrelated later argument's own nested
            # composables (see module docstring above `_extract_literals`).
            for m in ANDROID_CALL_PATTERN.finditer(text):
                open_paren = m.end() - 1
                record(open_paren + 1, _argument_span_end(text, open_paren + 1))

            # `title = if (x) "a" else "b"` / `AlertDialog(text = { Text(if
            # (x) "a" else "b") })` — any call this scanner doesn't otherwise
            # recognize by name, including AlertDialog's named slots.
            for m in ANDROID_KWARG_PATTERN.finditer(text):
                if not _PRECEDED_BY_ARG_BOUNDARY.search(text, 0, m.start()):
                    continue
                record(m.end(), _argument_span_end(text, m.end()))

            # `Modifier.semantics { contentDescription = if (x) "a" else "b" }` and friends — the a11y
            # assignment the kwarg pass above cannot see (its `{` isn't an arg boundary). (#571)
            for m in ANDROID_A11Y_ASSIGN_PATTERN.finditer(text):
                if _LOCAL_DECL_BEFORE.search(text, 0, m.start()):
                    continue
                span_end = _argument_span_end(text, m.end())
                record(m.end(), span_end)

                # The remaining #571 case: the assignment contains no literal
                # because a local `val` launders it. Follow only a bare
                # identifier to the nearest lexically-visible declaration;
                # pass-through parameters and arbitrary expressions remain
                # outside this targeted audit rule.
                reference = text[m.end():span_end].strip()
                if _SIMPLE_IDENTIFIER.fullmatch(reference):
                    initializer = _visible_val_initializer(text, reference, m.start())
                    if initializer is not None:
                        record(*initializer)

    return findings


# Keys that are deliberately identical in every language, so their absence from a locale file is not
# a gap. ONE definition: both the hard-gated focus locales and the #844 discovered ones subtract this,
# and a second copy would let the two paths disagree the moment anyone adds a key here.
ANDROID_EXEMPT_KEYS = {"app_name"}  # brand name


def android_strings_xml_gaps() -> dict[str, set[str]]:
    """Keys present in the base values/strings.xml but missing from an
    existing values-<locale>/strings.xml. (Doesn't invent missing locale dirs —
    see the audit summary for languages with NO directory at all.)"""
    base_path = ROOT / "android/app/src/main/res/values/strings.xml"
    # <plurals> count too: converting a hand-rolled singular/plural PAIR into one <plurals> would
    # otherwise DROP those keys out of this gate's view entirely, so a locale could silently lose them —
    # fixing the plural model must not open a coverage hole (see #540 for the same class of blind spot).
    base_keys = set(re.findall(r'<(?:string|plurals) name="([^"]+)"', base_path.read_text(encoding="utf-8")))
    gaps: dict[str, set[str]] = {}
    for lang in LANGS:
        locale_dir = ANDROID_LOCALE_DIRS[lang]
        lang_path = ROOT / f"android/app/src/main/res/{locale_dir}/strings.xml"
        if not lang_path.exists():
            gaps[lang] = {"<entire %s/ directory is missing>" % locale_dir}
            continue
        lang_keys = set(re.findall(r'<(?:string|plurals) name="([^"]+)"', lang_path.read_text(encoding="utf-8")))
        missing = (base_keys - ANDROID_EXEMPT_KEYS) - lang_keys
        if missing:
            gaps[lang] = missing
    return gaps


ANDROID_FORMAT_PATTERN = re.compile(r"%[1-9]\d*\$[-+0 #,(]*\d*(?:\.\d+)?([sdif])")


def android_format_gaps() -> dict[str, list[str]]:
    """Resource keys whose translated Formatter arguments differ from English."""
    paths = {
        "en": ROOT / "android/app/src/main/res/values/strings.xml",
        **{
            lang: ROOT / f"android/app/src/main/res/{ANDROID_LOCALE_DIRS[lang]}/strings.xml"
            for lang in LANGS
        },
    }
    def signature(value: str) -> list[str]:
        return sorted(ANDROID_FORMAT_PATTERN.findall(value))

    values: dict[str, dict[str, str]] = {}
    plural_items: dict[str, dict[str, list[str]]] = {}
    for lang, path in paths.items():
        if not path.exists():
            continue
        root = ET.parse(path).getroot()
        entries = {node.attrib["name"]: node.text or "" for node in root.findall("string")}
        items_by_key: dict[str, list[str]] = {}
        # <plurals> carry their format args on the <item> CHILDREN, so a plain findall("string") leaves
        # every plural's placeholders unchecked.
        #
        # Compare ONE REPRESENTATIVE form across languages, never the concatenated set: the signature is a
        # MULTISET, so folding would make it depend on how many quantity categories a language HAS —
        # Polish (one/few/many/other) would read as a format mismatch against English (one/other) purely
        # for having more forms, and this gate would reject the very thing <plurals> exist to support.
        # `other` is the CLDR fallback every language defines, so it is the stable representative.
        # A dropped placeholder in a NON-representative form is caught by the intra-plural check below.
        for node in root.findall("plurals"):
            items = node.findall("item")
            texts = [i.text or "" for i in items]
            rep = next((i.text or "" for i in items if i.attrib.get("quantity") == "other"),
                       texts[0] if texts else "")
            entries[node.attrib["name"]] = rep
            items_by_key[node.attrib["name"]] = texts
        values[lang] = entries
        plural_items[lang] = items_by_key

    gaps: dict[str, list[str]] = {}
    for lang in LANGS:
        if lang not in values:
            continue
        mismatched = [
            key for key, source in values["en"].items()
            if signature(source) != signature(values[lang].get(key, ""))
        ]
        # Every quantity form of ONE plural must carry the same placeholders as its siblings. This is a
        # within-language invariant, so it stays correct no matter how many categories the language has —
        # it catches the "translator dropped %1$d from just the `one` form" case that the representative
        # comparison above cannot see.
        for key, texts in plural_items.get(lang, {}).items():
            if len({tuple(signature(x)) for x in texts}) > 1 and key not in mismatched:
                mismatched.append(key)
        if mismatched:
            gaps[lang] = mismatched
    return gaps


# ---------------------------------------------------------------------------
# Apple: catalog drift + un-extracted literals
# ---------------------------------------------------------------------------

CATALOGS = [
    (
        [ROOT / "Packages/StrandDesign/Sources/StrandDesign"],
        ROOT / "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings",
    ),
    (
        [ROOT / "NOOPWatch"],
        ROOT / "NOOPWatch/Localizable.xcstrings",
    ),
    (
        [ROOT / "NOOPWatchComplications"],
        ROOT / "NOOPWatchComplications/Localizable.xcstrings",
    ),
    (
        [ROOT / "Strand", ROOT / "StrandiOS", ROOT / "StrandiOSShared", ROOT / "StrandiOSWidgets"],
        ROOT / "Strand/Resources/Localizable.xcstrings",
    ),
]

SWIFT_CALL_START_PATTERN = re.compile(
    r"\b(?:Text|Button|Label|Toggle|Menu|Picker|ProgressView|SectionHeader)\s*\("
    r"|"
    r"\.(?:navigationTitle|confirmationDialog|alert|accessibilityLabel|help)\s*\("
)

# A placeholder generated by Swift's LocalizedStringKey interpolation. The
# precise conversion depends on the interpolated value's static type, so the
# source-side audit deliberately accepts any valid String Catalog placeholder
# at that position instead of trying to reproduce compiler type inference.
CATALOG_PLACEHOLDER_PATTERN = r"%(?:(?:\d+)\$)?(?:@|[-+0 #']*(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|q|z|t|j)?[diuoxXfFeEgGaAcCsSp])"


def _skip_swift_string_literal(text: str, i: int) -> int:
    """`text[i]` is the opening `"` of a Swift string literal; return the
    index just past its closing `"`, honoring backslash escapes AND
    `\\(expr)` interpolation, which can itself contain a nested string
    literal (`Text("\\(String(format: "%.1f", value)) bpm")`) — a naive scan
    for the next `"` would end the OUTER literal early on that one."""
    i += 1
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            if text[i + 1] == "(":
                i += 2
                depth = 1
                while i < len(text) and depth:
                    c2 = text[i]
                    if c2 == '"':
                        i = _skip_swift_string_literal(text, i)
                        continue
                    if c2 == "(":
                        depth += 1
                    elif c2 == ")":
                        depth -= 1
                    i += 1
                continue
            i += 2
            continue
        if ch == '"':
            return i + 1
        i += 1
    return i


def _swift_argument_span_end(text: str, start: int) -> int:
    """`start` is just after a call's `(`; return the index where its first
    argument's expression ends — the next top-level comma, or the bracket
    that closes the call."""
    depth = 0
    i = start
    while i < len(text):
        ch = text[i]
        if ch == '"':
            i = _skip_swift_string_literal(text, i)
            continue
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            if depth == 0:
                return i
            depth -= 1
        elif ch == "," and depth == 0:
            return i
        i += 1
    return i


def swift_string_literals(text: str):
    """Yield (offset, literal contents) for every literal directly reachable
    in a localized SwiftUI call's FIRST argument — descends transparently
    through `(`/`[` (so `cond ? "a" : "b"` and nested calls are visible) but
    skips any `{...}` untouched (a SwiftUI trailing closure, e.g.
    `Button(action: { ... }) { Text("...") }`'s `action:` closure — not text,
    and whatever real text a trailing closure DOES carry, like that
    example's `Text("...")`, is found independently when the file-wide scan
    reaches it directly). Previously required the literal immediately after
    the call's `(`, so `Text(cond ? "Off" : "On")` was invisible — not just
    to this audit, but functionally: that ternary resolves to SwiftUI's
    non-localizing `Text<S: StringProtocol>` overload, so it was always
    English regardless of device language (#540).
    """
    for match in SWIFT_CALL_START_PATTERN.finditer(text):
        open_paren = match.end() - 1
        end = _swift_argument_span_end(text, open_paren + 1)
        i = open_paren + 1
        while i < end:
            ch = text[i]
            if ch == '"':
                j = _skip_swift_string_literal(text, i)
                yield i, text[i + 1:j - 1]
                i = j
                continue
            if ch == "{":
                depth = 1
                i += 1
                while i < end and depth:
                    c2 = text[i]
                    if c2 == '"':
                        i = _skip_swift_string_literal(text, i)
                        continue
                    if c2 in "({[":
                        depth += 1
                    elif c2 in ")}]":
                        depth -= 1
                    i += 1
                continue
            i += 1


def swift_catalog_pattern(literal: str) -> re.Pattern[str] | None:
    """Turn a Swift source literal into a regex for its compiled catalog key."""
    parts: list[str] = []
    cursor = 0
    i = 0
    found_interpolation = False
    while i < len(literal):
        if literal.startswith("\\(", i):
            found_interpolation = True
            static = swift_unescape(literal[cursor:i]).replace("%", "%%")
            parts.append(re.escape(static))
            depth = 1
            i += 2
            in_string = False
            while i < len(literal) and depth:
                ch = literal[i]
                if in_string:
                    if ch == "\\" and i + 1 < len(literal):
                        i += 2
                        continue
                    if ch == '"':
                        in_string = False
                elif ch == '"':
                    in_string = True
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                i += 1
            parts.append(CATALOG_PLACEHOLDER_PATTERN)
            cursor = i
        else:
            i += 1
    if not found_interpolation:
        return None
    parts.append(re.escape(swift_unescape(literal[cursor:]).replace("%", "%%")))
    return re.compile("^" + "".join(parts) + "$")


def swift_unescape(value: str) -> str:
    """Decode the Swift escapes that can appear in catalog source text."""
    value = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), value)
    replacements = {
        r'\"': '"',
        r"\'": "'",
        r"\n": "\n",
        r"\r": "\r",
        r"\t": "\t",
        r"\\": "\\",
    }
    for escaped, decoded in replacements.items():
        value = value.replace(escaped, decoded)
    return value


def swift_catalog_lookup(cat: dict, literal: str) -> dict | None:
    """Find a direct or compiler-normalized String Catalog entry."""
    direct = catalog_lookup(cat, swift_unescape(literal))
    if direct is not None:
        return direct
    pattern = swift_catalog_pattern(literal)
    if pattern is None:
        return None
    for key, entry in cat.get("strings", {}).items():
        if pattern.fullmatch(key):
            return entry
    return None


APPLE_FORMAT_PATTERN = re.compile(
    r"%(?:(?:\d+)\$)?(@|(?:hh|h|ll|l|q|z|t|j)?[diuoxXfFeEgGaAcCsSp])"
)


def _string_units(entry: dict, lang: str) -> list[dict]:
    """Every stringUnit a localization carries — plain value OR plural variations.

    An xcstrings localization is either

        localizations.<lang>.stringUnit

    or, once the string has plural forms,

        localizations.<lang>.variations.plural.<category>.stringUnit

    (device variations nest the same way, and the two can combine). Reading only the FIRST shape makes
    every pluralised entry look untranslated to this gate — so converting a hand-rolled ternary into real
    plural variations would red-flag the string in every language. Walk both shapes.
    """
    loc = (entry.get("localizations", {}) or {}).get(lang) or {}
    units: list[dict] = []
    unit = loc.get("stringUnit")
    if isinstance(unit, dict):
        units.append(unit)

    def walk(node: object) -> None:
        if not isinstance(node, dict):
            return
        for key, value in node.items():
            if key == "stringUnit" and isinstance(value, dict):
                units.append(value)
            elif isinstance(value, dict):
                walk(value)

    walk(loc.get("variations") or {})
    return units


def _is_translated(entry: dict, lang: str) -> bool:
    """True when the localization exists AND every one of its stringUnits is translated — so a plural
    with one category still marked `new` is correctly reported as a gap, not silently accepted."""
    units = _string_units(entry, lang)
    return bool(units) and all(u.get("state") == "translated" for u in units)


def apple_format_gaps(cat: dict, lang: str) -> list[str]:
    """Catalog keys whose localized printf arguments differ from the source."""
    def signature(value: str) -> list[str]:
        return sorted(APPLE_FORMAT_PATTERN.findall(value))

    mismatched = []
    for key, entry in cat.get("strings", {}).items():
        if entry.get("shouldTranslate") is False:
            continue
        # Compare EVERY form independently against the key, never a folded concatenation: folding would
        # make the signature depend on how many plural categories the language HAS (ru/pl carry four,
        # zh one), so a correct translation would read as a format mismatch purely for having more forms.
        values = [u.get("value", "") for u in _string_units(entry, lang)] or [""]
        if any(signature(key) != signature(v) for v in values):
            mismatched.append(key)
    return mismatched


def load_catalog(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def catalog_lookup(cat: dict, key: str) -> dict | None:
    return cat.get("strings", {}).get(key)


def scan_ios() -> tuple[list[tuple[str, int, str]], dict[str, list[str]]]:
    hardcoded: list[tuple[str, int, str]] = []  # not in any catalog at all
    lang_gaps: dict[str, list[str]] = {lang: [] for lang in LANGS}

    for dirs, catalog_path in CATALOGS:
        cat = load_catalog(catalog_path)
        for base in dirs:
            if not base.exists():
                continue
            for path in sorted(base.rglob("*.swift")):
                text = path.read_text(encoding="utf-8", errors="replace")
                for offset, literal in swift_string_literals(text):
                    if not is_probably_ui_text(literal):
                        continue
                    entry = swift_catalog_lookup(cat, literal)
                    line_no = text.count("\n", 0, offset) + 1
                    rel = str(path.relative_to(ROOT))
                    if entry is None:
                        hardcoded.append((rel, line_no, literal))
                        continue
                    if entry.get("shouldTranslate") is False:
                        continue
                    for lang in LANGS:
                        if not _is_translated(entry, lang):
                            lang_gaps[lang].append(f"{catalog_path.relative_to(ROOT)} :: {literal!r}")
    for lang in lang_gaps:
        lang_gaps[lang] = sorted(set(lang_gaps[lang]))
    return hardcoded, lang_gaps


# Languages the audit hard-gates at ZERO missing keys. Historically the ONLY languages it looked at
# — which is why they sit at 100% while everything else drifted. Unchanged here: still zero tolerance.
#
# Every OTHER shipped locale is discovered below and gated against a ratcheting allowance instead, so
# switching coverage on does not red-check every open PR with hundreds of pre-existing gaps (#844).
EXTRA_LOCALE_BASELINE_PATH = ROOT / "Tools/i18n_extra_locale_baseline.txt"


def shipped_apple_langs(cat: dict) -> set[str]:
    """Every non-English localization the catalog actually carries.

    Read from the catalog rather than a constant so a language is covered the day it appears. The
    hardcoded LANGS is what let `it`, `ru`, `zh-Hans` and `zh-Hant` ship for months at up to 85%
    untranslated while the audit reported green (#844).
    """
    langs: set[str] = set()
    for v in cat.get("strings", {}).values():
        langs |= set((v.get("localizations") or {}).keys())
    return langs - {"en"}


def shipped_android_locale_dirs() -> list[str]:
    """Every `values-<locale>` directory on disk, not just the four in ANDROID_LOCALE_DIRS.

    `values-zh` has existed and been unchecked long enough to fall 43 keys behind (#844).
    """
    res = ROOT / "android/app/src/main/res"
    return sorted(d.name for d in res.glob("values-*") if (d / "strings.xml").exists())


def extra_locale_allowance() -> dict[str, int]:
    """`target -> allowed missing count` for the newly-covered locales.

    Counts rather than key lists, for the same reason as Tools/doc_comment_lint_baseline.txt: a key
    list goes stale on every edit and trains people to regenerate it unread, while a count moves only
    when someone adds or removes a gap. Ratchets DOWN — closing gaps prints an IMPROVED line.
    """
    if not EXTRA_LOCALE_BASELINE_PATH.exists():
        return {}
    out: dict[str, int] = {}
    for raw in EXTRA_LOCALE_BASELINE_PATH.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        target, _, count = line.rpartition(" ")
        out[target.strip()] = int(count)
    return out


BASELINE_PATH = ROOT / "Tools/i18n_audit_baseline.json"


def load_baseline() -> dict[str, set[tuple[str, str]]]:
    """Pre-existing hardcoded-literal findings, keyed by (path, literal) —
    not line number, which drifts on any unrelated edit to the same file.

    #540's scanner fix went from missing whole classes of conditionally-
    hidden literals (7 known Android sites) to correctly finding 248 real
    ones once it could see through if/else, when, and .let — far more than
    one PR can respect while writing careful, non-machine-slop translations
    for (see #543 on what rushing that produces). This baseline lets the
    scanner itself land immediately — CI blocks any NEW hardcoded literal
    from this point on — while the pre-existing backlog is closed
    incrementally in separate, appropriately-sized follow-up PRs. Regenerate
    with `--update-baseline` after closing some of it; an entry that no
    longer appears in a fresh scan is simply inert, not an error."""
    if not BASELINE_PATH.exists():
        return {"android": set(), "ios": set()}
    data = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))
    return {
        "android": {(p, lit) for p, lit in data.get("android", [])},
        "ios": {(p, lit) for p, lit in data.get("ios", [])},
    }


def write_baseline() -> None:
    android = sorted({(p, lit) for p, _line, lit in scan_android()})
    ios_hardcoded, _gaps = scan_ios()
    ios = sorted({(p, lit) for p, _line, lit in ios_hardcoded})
    BASELINE_PATH.write_text(
        json.dumps({"android": android, "ios": ios}, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {len(android)} android + {len(ios)} ios entries to {BASELINE_PATH.relative_to(ROOT)}")


def ci_check(base_ref: str) -> int:
    """Strict CI gate: the #453 backlog is closed, so every focus language
    translation must remain complete, and no NEW hardcoded literal may land
    (pre-existing ones are tracked in the baseline — see load_baseline()).
    ``base_ref`` remains in the CLI for workflow compatibility but coverage
    is now a standing invariant, not a diff-scoped allowance.
    """
    failed = False
    baseline = load_baseline()

    print("--- Android: no NEW hardcoded UI copy, and complete focus locales ---")
    android_literals = scan_android()
    android_found = {(p, lit) for p, _line, lit in android_literals}
    android_new = [f for f in android_literals if (f[0], f[2]) not in baseline["android"]]
    if android_new:
        failed = True
        print(f"FAIL {len(android_new)} NEW hardcoded literal(s) (not in {BASELINE_PATH.relative_to(ROOT)}):")
        for path, line, literal in android_new[:30]:
            print(f"  {path}:{line}: {literal!r}")
    else:
        print(f"  OK no new hardcoded literals ({len(android_found)} pre-existing, tracked in the baseline)")
    android_fixed = baseline["android"] - android_found
    if android_fixed:
        print(f"  {len(android_fixed)} baseline entr(y/ies) no longer found — run --update-baseline to shrink the backlog")
    android_gaps = android_strings_xml_gaps()
    android_formats = android_format_gaps()
    for lang in LANGS:
        gaps = android_gaps.get(lang)
        if gaps:
            failed = True
            locale_dir = ANDROID_LOCALE_DIRS[lang]
            print(f"FAIL {locale_dir}/strings.xml missing {len(gaps)} key(s): {sorted(gaps)[:30]}")
        else:
            locale_dir = ANDROID_LOCALE_DIRS[lang]
            print(f"  OK {locale_dir}/strings.xml")
        format_gaps = android_formats.get(lang)
        if format_gaps:
            failed = True
            locale_dir = ANDROID_LOCALE_DIRS[lang]
            print(f"FAIL {locale_dir}/strings.xml has {len(format_gaps)} format mismatch(es): {format_gaps[:30]}")

    print("\n--- Apple: no NEW un-extracted UI copy, and complete focus locales ---")
    ios_literals, _source_gaps = scan_ios()
    ios_found = {(p, lit) for p, _line, lit in ios_literals}
    ios_new = [f for f in ios_literals if (f[0], f[2]) not in baseline["ios"]]
    if ios_new:
        failed = True
        print(f"FAIL {len(ios_new)} NEW literal(s) absent from their target catalog:")
        for path, line, literal in ios_new[:30]:
            print(f"  {path}:{line}: {literal!r}")
    else:
        print(f"  OK no new un-extracted literals ({len(ios_found)} pre-existing, tracked in the baseline)")
    ios_fixed = baseline["ios"] - ios_found
    if ios_fixed:
        print(f"  {len(ios_fixed)} baseline entr(y/ies) no longer found — run --update-baseline to shrink the backlog")
    allowance = extra_locale_allowance()
    extra_apple_gaps: dict[str, int] = {}
    for _dirs, catalog_path in CATALOGS:
        cat = load_catalog(catalog_path)
        # #844: count the shipped locales OUTSIDE the focus set while the catalog is already parsed,
        # and gate them below. Reloading each catalog for a second pass wasted a full re-parse of a
        # 3255-string file.
        for extra in sorted(shipped_apple_langs(cat) - set(LANGS)):
            extra_apple_gaps[f"{catalog_path.relative_to(ROOT)}:{extra}"] = sum(
                1 for v in cat.get("strings", {}).values()
                if v.get("shouldTranslate") is not False and not _is_translated(v, extra)
            )
        for lang in LANGS:
            missing = sum(
                1 for v in cat.get("strings", {}).values()
                if v.get("shouldTranslate") is not False and not _is_translated(v, lang)
            )
            if missing:
                failed = True
                print(f"FAIL {catalog_path.relative_to(ROOT)} {lang}: missing={missing}")
            else:
                print(f"  OK {catalog_path.relative_to(ROOT)} {lang}")
            format_gaps = apple_format_gaps(cat, lang)
            if format_gaps:
                failed = True
                print(f"FAIL {catalog_path.relative_to(ROOT)} {lang}: {len(format_gaps)} format mismatch(es): {format_gaps[:10]}")

    # #844: every OTHER shipped locale, gated against a ratcheting allowance. LANGS above stays at zero
    # tolerance; these carry real pre-existing debt (StrandDesign ships 14 of 95 Italian), so the gate
    # blocks GROWTH rather than demanding the backlog be cleared before anyone can merge.
    print("\n--- Locales beyond the focus set: no NEW gaps (ratcheting allowance) ---")
    # Local, NOT the global `failed`: an earlier section failing (a German string, an un-extracted
    # literal) must not silence this section's own verdict. Reporting nothing here reads as "did not
    # run", which is the worst thing a gate can say to someone trying to understand a red build.
    locale_failed = False
    improved: list[str] = []
    seen_targets: set[str] = set()
    for target, missing in sorted(extra_apple_gaps.items()):
        seen_targets.add(target)
        allowed = allowance.get(target, 0)
        if missing > allowed:
            failed = True
            locale_failed = True
            print(f"FAIL {target}: missing={missing} exceeds the allowance of {allowed}")
        elif missing < allowed:
            improved.append(f"{target}: {allowed} -> {missing}")
    base_path = ROOT / "android/app/src/main/res/values/strings.xml"
    base_keys = set(re.findall(r'<(?:string|plurals) name="([^"]+)"', base_path.read_text(encoding="utf-8")))
    for locale_dir in shipped_android_locale_dirs():
        if locale_dir in ANDROID_LOCALE_DIRS.values():
            continue   # already hard-gated above
        lang_path = ROOT / f"android/app/src/main/res/{locale_dir}/strings.xml"
        lang_keys = set(re.findall(r'<(?:string|plurals) name="([^"]+)"', lang_path.read_text(encoding="utf-8")))
        missing = len((base_keys - ANDROID_EXEMPT_KEYS) - lang_keys)
        target = f"{locale_dir}/strings.xml"
        seen_targets.add(target)
        allowed = allowance.get(target, 0)
        if missing > allowed:
            failed = True
            locale_failed = True
            print(f"FAIL {target}: missing={missing} exceeds the allowance of {allowed}")
        elif missing < allowed:
            improved.append(f"{target}: {allowed} -> {missing}")
    # An allowance for a target that no longer exists (locale removed, catalog dropped) can never be
    # satisfied and silently inflates the tracked total, so surface it rather than let it rot.
    for stale in sorted(set(allowance) - seen_targets):
        print(f"  STALE {stale} is no longer present — drop it from {EXTRA_LOCALE_BASELINE_PATH.name}.")
    for line in improved:
        print(f"  IMPROVED {line}. Lower it in {EXTRA_LOCALE_BASELINE_PATH.name}.")
    if not locale_failed:
        tracked = sum(allowance.values())
        print(f"  OK no new gaps in the non-focus locales ({tracked} tracked, ratcheting down)")

    return 1 if failed else 0


def catalog_summary() -> None:
    print("\n--- Apple catalogs: translated-key coverage (existing keys, any source) ---")
    for _dirs, catalog_path in CATALOGS:
        cat = load_catalog(catalog_path)
        strings = cat.get("strings", {})
        total = len(strings)
        line = f"{catalog_path.relative_to(ROOT)} ({total} keys):"
        # #844: report every locale the catalog actually ships, not just the focus four. Showing only
        # LANGS is very likely WHY the drift went unnoticed for so long — this summary read 100% across
        # the board while `it` sat at 14 of 95. The gate and the human-readable view must see the same
        # set, or the view quietly reassures you about languages nobody is checking.
        for lang in sorted(set(LANGS) | shipped_apple_langs(cat)):
            missing = 0
            for v in strings.values():
                if v.get("shouldTranslate") is False:
                    continue
                state = (v.get("localizations", {}).get(lang) or {}).get("stringUnit", {}).get("state")
                if state != "translated":
                    missing += 1
            line += f"  {lang} missing={missing}"
        print(" ", line)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", choices=["ios", "android", "all"], default="all")
    ap.add_argument("--full", action="store_true", help="print every finding, not just counts")
    ap.add_argument("--ci", metavar="BASE_REF", help="strict coverage gate (BASE_REF is retained for workflow compatibility); see ci_check() docstring")
    ap.add_argument("--update-baseline", action="store_true", help="rewrite Tools/i18n_audit_baseline.json from the current hardcoded-literal scan (see load_baseline() docstring). Does NOT touch Tools/i18n_extra_locale_baseline.txt — that one is lowered by hand, so shrinking it stays a deliberate act")
    args = ap.parse_args()

    if args.update_baseline:
        write_baseline()
        return 0

    if args.ci:
        return ci_check(args.ci)

    if args.platform in ("android", "all"):
        print("=== Android: hardcoded UI literals (never localized) ===")
        findings = scan_android()
        print(f"{len(findings)} hardcoded literal(s) found under android/app/.../ui|widget")
        if args.full:
            for rel, line_no, literal in findings:
                print(f"  {rel}:{line_no}: {literal!r}")
        else:
            for rel, line_no, literal in findings[:25]:
                print(f"  {rel}:{line_no}: {literal!r}")
            if len(findings) > 25:
                print(f"  ... and {len(findings) - 25} more (use --full)")

        print("\n=== Android: values-<locale>/strings.xml key gaps ===")
        gaps = android_strings_xml_gaps()
        if not gaps:
            print("  none (focus locales all present and complete, or no locale dir exists)")
        for lang, keys in gaps.items():
            print(f"  {lang}: {len(keys)} gap(s)")
            if args.full:
                for k in sorted(keys):
                    print(f"    {k}")

    if args.platform in ("ios", "all"):
        print("\n=== Apple: hardcoded/un-extracted Swift literals (not in any catalog) ===")
        hardcoded, lang_gaps = scan_ios()
        print(f"{len(hardcoded)} literal(s) not present in their target's String Catalog")
        if args.full:
            for rel, line_no, literal in hardcoded:
                print(f"  {rel}:{line_no}: {literal!r}")
        else:
            for rel, line_no, literal in hardcoded[:25]:
                print(f"  {rel}:{line_no}: {literal!r}")
            if len(hardcoded) > 25:
                print(f"  ... and {len(hardcoded) - 25} more (use --full)")

        print("\n=== Apple: catalog keys present but not translated, per language ===")
        for lang in LANGS:
            entries = lang_gaps[lang]
            print(f"  {lang}: {len(entries)} gap(s)")
            if args.full:
                for e in entries:
                    print(f"    {e}")

        catalog_summary()

    return 0


if __name__ == "__main__":
    sys.exit(main())
