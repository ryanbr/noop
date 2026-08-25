"""Tests for the #540 fix: i18n_audit.py must see UI-text literals hidden
behind if/else, when, and .let — not just literals sitting immediately after
Text(/title=/etc — without also sweeping unrelated nested composable subtrees
(the bug in the first draft of this fix, which produced 489 findings instead
of a few dozen).

Run: python3 -m unittest Tools.test_i18n_audit -v   (from the repo root)
     or: cd Tools && python3 -m unittest test_i18n_audit -v
"""

import json
import tempfile
import unittest
from pathlib import Path

import i18n_audit as ia


def literals(text: str) -> list[str]:
    """Every literal `_extract_literals` finds across the whole snippet,
    content only (offsets aren't interesting for these tests)."""
    return [lit for _offset, lit in ia._extract_literals(text, 0, len(text))]


class AndroidLiteralExtraction(unittest.TestCase):
    def test_plain_literal(self):
        self.assertEqual(literals('Text("Save")'), ["Save"])

    def test_ternary_if_else_expression(self):
        # The issue's exact reported bug (HrvSnapshotScreen.kt:290).
        self.assertEqual(literals('Text(if (saved) "Saved" else "Save")'), ["Saved", "Save"])

    def test_block_bodied_if_else(self):
        # SleepScreen.kt:2249-shaped: braces around each branch.
        text = 'Text(if (session.userEdited) { "Removes edited" } else { "Removes recorded" })'
        self.assertEqual(literals(text), ["Removes edited", "Removes recorded"])

    def test_let_as_null_coalescing_ternary(self):
        # CaffeineLog.kt:297-shaped.
        text = 'Text(estimate?.let { "About it" } ?: "Caffeine may still be active")'
        self.assertEqual(literals(text), ["About it", "Caffeine may still be active"])

    def test_when_with_subject(self):
        text = 'Text(when (stage) { "Awake" -> "Awake now" else -> "Unknown" })'
        self.assertIn("Awake now", literals(text))
        self.assertIn("Unknown", literals(text))

    def test_bare_when(self):
        text = 'Text(when { cond1 -> "a" else -> "b" })'
        self.assertEqual(literals(text), ["a", "b"])

    def test_nested_composable_slot_not_swept(self):
        # A trailing lambda that is NOT if/when/.let is a separate,
        # independently-composed subtree (the 489-finding regression this
        # fix must not reintroduce) — nothing should be found INSIDE it from
        # here; the nested Text(...) is discovered on its own, separate pass.
        text = 'AlertDialog(text = { Column { Text("Unrelated deep content") } })'
        kwarg_start = text.index("{ Column")
        span_end = ia._argument_span_end(text, text.index("=", text.index("text")) + 1)
        self.assertEqual(literals(text[kwarg_start:span_end]), [])

    def test_plus_concatenation_skipped(self):
        # uiString(R.string.x) + "hardcoded suffix" is a real, but explicitly
        # DIFFERENT and out-of-scope bug (partial localization via an
        # engineered prefix) — tracked separately, not by this scanner.
        text = 'Text(uiString(R.string.x) + "hardcoded suffix")'
        self.assertEqual(literals(text), [])

    def test_plus_concatenation_does_not_swallow_a_real_conditional(self):
        # LiveScreen.kt:1068-shaped: the first branch is a real, standalone
        # conditional literal; only the +-joined unit-suffix is excluded.
        text = 'Text(if (empty) "Waiting." else "Recent: " + values.joinToString() + " ms")'
        self.assertEqual(literals(text), ["Waiting.", "Recent: "])

    def test_string_template_interpolation_not_corrupted(self):
        # MindSection.kt:167-shaped pluralization idiom: a nested literal
        # inside ${...} must not be mistaken for the end of the outer one.
        text = 'Text("$left more ${if (left == 1) "day" else "days"} to go.")'
        self.assertEqual(literals(text), ['$left more ${if (left == 1) "day" else "days"} to go.'])


class ArgumentSpanDetection(unittest.TestCase):
    """`AndroidLiteralExtraction` above hands `_extract_literals` a span that is
    already correct, so it never exercises `_argument_span_end` — the function
    that decides where a `Text(...)` argument actually ends in real source, and
    the piece most likely to break under future edits (nested bracket balancing
    plus transparent-vs-opaque brace classification).

    Both tests use a multi-arg call whose first argument has braced branches, so
    they fail in BOTH directions: stopping one brace early truncates the span
    mid-conditional, and running past the top-level comma swallows the sibling
    arguments.
    """

    # `if (x) { … } else { … }` (not the flat ternary) is deliberate: without a
    # brace in the argument, an early-stopping regression is invisible.
    SOURCE = 'Text(if (x) { "Saved" } else { "Save" }, modifier = Modifier.testTag("hrv_row"))'

    def test_span_ends_at_top_level_comma_not_at_a_nested_brace(self):
        start = self.SOURCE.index("(") + 1
        end = ia._argument_span_end(self.SOURCE, start)
        self.assertEqual(self.SOURCE[start:end], 'if (x) { "Saved" } else { "Save" }')

    def test_extraction_over_the_real_span_excludes_sibling_arguments(self):
        # `hrv_row` is the overrun canary: it is only reachable if the span runs
        # past the comma. (It could not do this job through `scan_android()` —
        # `is_probably_ui_text` filters snake_case testTags out again.)
        start = self.SOURCE.index("(") + 1
        end = ia._argument_span_end(self.SOURCE, start)
        found = [lit for _offset, lit in ia._extract_literals(self.SOURCE, start, end)]
        self.assertEqual(found, ["Saved", "Save"])


class MaskComments(unittest.TestCase):
    def test_line_comment_blanked(self):
        text = 'val x = 1 // "Take over this ring?"\nText("Real")'
        masked = ia._mask_comments(text)
        self.assertNotIn("Take over", masked)
        self.assertIn('Text("Real")', masked)
        self.assertEqual(len(masked), len(text))  # offsets/line numbers preserved

    def test_block_comment_blanked(self):
        text = 'Text(/* "fake" */ "Real")'
        masked = ia._mask_comments(text)
        self.assertNotIn("fake", masked)
        self.assertIn("Real", masked)

    def test_comment_marker_inside_string_not_treated_as_comment(self):
        text = 'Text("http://example.com // not a comment")'
        masked = ia._mask_comments(text)
        self.assertIn("not a comment", masked)


class FormatSpecExclusion(unittest.TestCase):
    def test_pure_format_spec_excluded(self):
        self.assertFalse(ia.is_probably_ui_text("%.1f"))
        self.assertFalse(ia.is_probably_ui_text("%02d"))
        self.assertFalse(ia.is_probably_ui_text("%+.2f"))

    def test_format_spec_with_real_text_kept(self):
        self.assertTrue(ia.is_probably_ui_text("%.1f br/min"))


class ScanAndroidEndToEnd(unittest.TestCase):
    """Exercises scan_android() against real files on disk (its actual
    contract), not just the pure-function helpers above."""

    def setUp(self):
        # Must live under ia.ROOT: scan_android() reports paths via
        # `path.relative_to(ROOT)`, which raises for anything outside it.
        self.tmp = tempfile.TemporaryDirectory(dir=ia.ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.ui_dir = Path(self.tmp.name) / "ui"
        self.ui_dir.mkdir()
        self._orig_dirs = ia.ANDROID_DIRS
        ia.ANDROID_DIRS = [self.ui_dir]
        self.addCleanup(setattr, ia, "ANDROID_DIRS", self._orig_dirs)

    def write(self, name: str, content: str) -> None:
        (self.ui_dir / name).write_text(content, encoding="utf-8")

    def test_conditional_literal_found(self):
        self.write("Screen.kt", 'Text(if (saved) "Saved" else "Save")')
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"Saved", "Save"})

    def test_alert_dialog_kwarg_conditional_found(self):
        self.write(
            "Screen.kt",
            'AlertDialog(onDismissRequest = {}, title = { Text(if (x) "A" else "B") })',
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"A", "B"})

    def test_notification_builder_literals_found(self):
        # A NotificationCompat chain is not Compose: it has no `Text(` and no
        # `title=`/`text=` kwarg, so every pattern here missed it and the whole
        # notification surface — including the always-on foreground-service one —
        # shipped English in every locale unnoticed. Adding the two setters to
        # ANDROID_CALL_PATTERN is what surfaced it (#867).
        self.write(
            "Notifier.kt",
            "NotificationCompat.Builder(context, CHANNEL_ID)\n"
            '    .setContentTitle("Strap battery low")\n'
            '    .setContentText("Recharge your WHOOP before tonight.")\n'
            "    .build()\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"Strap battery low", "Recharge your WHOOP before tonight."})

    def test_notification_builder_resource_lookup_not_flagged(self):
        # The fixed form must stay green, or the pattern above would be reverted
        # the first time it cried wolf on a correctly-localised notifier.
        self.write(
            "Notifier.kt",
            "NotificationCompat.Builder(context, CHANNEL_ID)\n"
            "    .setContentTitle(context.getString(R.string.battery_low_title))\n"
            "    .setContentText(body)\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_local_val_declaration_not_scanned_as_kwarg(self):
        # `val text = when { ... }` is a local declaration, not a composable
        # kwarg — ANDROID_KWARG_PATTERN's `text=` must not treat its `when`
        # branch match-keys as UI-text findings.
        self.write(
            "Screen.kt",
            'val text = when (stage) {\n    "Awake" -> "Awake now"\n    else -> "Unknown"\n}\n',
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_no_explosion_from_nested_slot_lambda(self):
        # The 489-finding regression guard: a huge, unrelated nested
        # composable subtree inside a title=/text= slot must not get swept.
        self.write(
            "Wizard.kt",
            "AlertDialog(\n"
            "    onDismissRequest = {},\n"
            "    text = {\n"
            "        Column {\n"
            '            Text("First deep child")\n'
            '            Text("Second deep child")\n'
            "        }\n"
            "    },\n"
            ")",
        )
        found = [lit for _p, _l, lit in ia.scan_android()]
        # Both literals are still found — but because the file-wide scan
        # reaches each nested Text(...) call directly, not because the
        # outer AlertDialog's text= span was swept.
        self.assertEqual(sorted(found), ["First deep child", "Second deep child"])

    # --- #571: contentDescription assigned inside a `semantics {}` lambda ---

    def test_content_description_in_semantics_lambda_found(self):
        # The standard Compose a11y idiom: the `{` is not an arg boundary, so the
        # general kwarg pass skips it — the dedicated assignment pass must catch it.
        self.write(
            "A.kt",
            'Modifier.semantics { contentDescription = if (hr) "Recovery ready" else "Recovery, no data yet" }',
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"Recovery ready", "Recovery, no data yet"})

    def test_content_description_multiline_semantics_found(self):
        self.write(
            "A.kt",
            "Modifier.semantics {\n    contentDescription = \"Charge calibrating tonight\"\n}",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"Charge calibrating tonight"})

    def test_content_description_pass_excludes_decl_and_member_read(self):
        # A `val` local decl and a `.member ==` comparison are NOT a11y UI-text sites;
        # neither may be flagged (guards the pass against false positives).
        self.write(
            "A.kt",
            'val contentDescription = "local decl not ui"\n'
            'if (view.contentDescription == "compare not ui") doThing()\n',
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_content_description_lambda_does_not_reopen_unrelated_slot(self):
        # The a11y pass must not resurrect the 489-explosion: an unrelated slot
        # lambda beside a contentDescription assignment stays scanned only on its own.
        self.write(
            "A.kt",
            'Box(Modifier.semantics { contentDescription = "Tap target" }) {\n'
            '    AlertDialog(text = { Column { Text("Deep child") } })\n'
            "}",
        )
        found = sorted(lit for _p, _l, lit in ia.scan_android())
        self.assertEqual(found, ["Deep child", "Tap target"])

    def test_content_description_follows_visible_local_val(self):
        # The remaining #571 case: the a11y assignment contains only a
        # reference, while its visible local initializer carries the UI copy.
        self.write(
            "Coupled.kt",
            "fun Hero() {\n"
            "    val a11y = when {\n"
            '        ready -> "Recovery $score percent"\n'
            '        calibrating -> "Recovery calibrating, $n nights"\n'
            '        else -> "Recovery, no data yet"\n'
            "    }\n"
            "    Box(Modifier.semantics { contentDescription = a11y })\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(
            found,
            {
                "Recovery $score percent",
                "Recovery calibrating, $n nights",
                "Recovery, no data yet",
            },
        )

    def test_content_description_does_not_follow_parameter(self):
        self.write(
            "Component.kt",
            "fun Label(content: String) {\n"
            "    Box(Modifier.semantics { contentDescription = content })\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_content_description_respects_val_scope(self):
        self.write(
            "Sibling.kt",
            "fun Screen() {\n"
            "    if (condition) {\n"
            '        val a11y = "Sibling-only text"\n'
            "    }\n"
            "    Box(Modifier.semantics { contentDescription = a11y })\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_content_description_uses_nearest_shadowing_val(self):
        self.write(
            "Shadowed.kt",
            "fun Screen() {\n"
            '    val a11y = "Outer hardcoded text"\n'
            "    if (condition) {\n"
            "        val a11y = uiString(R.string.localized)\n"
            "        Box(Modifier.semantics { contentDescription = a11y })\n"
            "    }\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_val_initializer_does_not_sweep_following_statements(self):
        self.write(
            "Bounded.kt",
            "fun Screen() {\n"
            '    val a11y = "Target text"\n'
            '    val internal = "Not accessibility text"\n'
            "    Box(Modifier.semantics { contentDescription = a11y })\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"Target text"})

    def test_val_initializer_follows_explicit_line_continuation(self):
        self.write(
            "Continued.kt",
            "fun Screen() {\n"
            '    val a11y = "Workout row" +\n'
            "        if (selected) {\n"
            '            ". Selected."\n'
            "        } else {\n"
            '            ". Not selected."\n'
            "        }\n"
            "    Box(Modifier.semantics { contentDescription = a11y })\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(
            found,
            {"Workout row", ". Selected.", ". Not selected."},
        )


class Baseline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._orig_path = ia.BASELINE_PATH
        ia.BASELINE_PATH = Path(self.tmp.name) / "baseline.json"
        self.addCleanup(setattr, ia, "BASELINE_PATH", self._orig_path)

    def test_missing_baseline_is_empty(self):
        self.assertEqual(ia.load_baseline(), {"android": set(), "ios": set()})

    def test_round_trip(self):
        ia.BASELINE_PATH.write_text(
            json.dumps({"android": [["Screen.kt", "Old"]], "ios": []}), encoding="utf-8"
        )
        baseline = ia.load_baseline()
        self.assertEqual(baseline["android"], {("Screen.kt", "Old")})
        self.assertEqual(baseline["ios"], set())

    def test_baseline_keyed_by_path_and_literal_not_line(self):
        # A baseline entry must keep suppressing a finding whose line number
        # shifted from an unrelated edit elsewhere in the same file.
        ia.BASELINE_PATH.write_text(
            json.dumps({"android": [["Screen.kt", "Save"]], "ios": []}), encoding="utf-8"
        )
        baseline = ia.load_baseline()
        finding = ("Screen.kt", 999, "Save")  # line number drifted
        self.assertIn((finding[0], finding[2]), baseline["android"])


class EchoDetectionWordFilter(unittest.TestCase):
    """`_has_translatable_words` is the false-positive guard for the echo gate: it decides whether a
    string identical across languages is a suspicious untranslated ECHO or a legitimately-identical
    term. It backs both the iOS (key == source) and Android (base value) echo counts."""

    def test_real_phrase_is_translatable(self):
        self.assertTrue(ia._has_translatable_words("Add a daily action"))
        self.assertTrue(ia._has_translatable_words("Predictive runtime warning"))

    def test_format_only_string_is_not(self):
        # Placeholders + punctuation with nothing to translate — a locale repeating them is CORRECT.
        self.assertFalse(ia._has_translatable_words("%@ · %lld"))
        self.assertFalse(ia._has_translatable_words("%1$s: %2$s. %3$s"))

    def test_single_word_term_is_not(self):
        # One word is very often a term of art / brand that legitimately travels.
        self.assertFalse(ia._has_translatable_words("HRV"))
        self.assertFalse(ia._has_translatable_words("Yoga"))

    def test_symbols_and_punctuation_are_not(self):
        self.assertFalse(ia._has_translatable_words("· • —"))

    def test_android_positional_specifiers_are_stripped(self):
        # "vs prev %1$s" keeps the words "vs"/"prev" — a Spanish copy repeating it verbatim is an echo.
        self.assertTrue(ia._has_translatable_words("vs prev %1$s"))
        # "%1$d%%" is pure format + literal percent — nothing to translate.
        self.assertFalse(ia._has_translatable_words("%1$d%%"))

    def test_two_word_brand_is_flagged(self):
        # Deliberately True: "Apple Health" IS caught, and the ratchet baseline absorbs it as an allowed
        # legitimate echo — the gate's job is to block GROWTH, not to pre-judge every identical string.
        self.assertTrue(ia._has_translatable_words("Apple Health"))


if __name__ == "__main__":
    unittest.main()


class CatalogSummaryPluralCoverage(unittest.TestCase):
    """The human-readable coverage summary must count plural entries the same way the gate does.

    `catalog_summary` used to read `localizations[lang].stringUnit.state` directly. A pluralised entry
    keeps its units under `variations.plural.<category>.stringUnit`, so that flat lookup returned None
    and scored a fully-translated plural as a gap — it reported de/es/fr/pt-PT missing=4 and pl missing=5
    on the Strand catalog when every one of those was translated in every form, and it made Polish look
    worst-covered precisely because it correctly carries one/few/many/other.
    """

    def _summary(self, catalog: dict) -> str:
        import contextlib
        import io
        saved_catalogs, saved_load = ia.CATALOGS, ia.load_catalog
        try:
            ia.CATALOGS = [((), ia.ROOT / "fixture" / "Localizable.xcstrings")]
            ia.load_catalog = lambda _path: catalog
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                ia.catalog_summary()
            return buf.getvalue()
        finally:
            ia.CATALOGS, ia.load_catalog = saved_catalogs, saved_load

    @staticmethod
    def _plural(states: dict[str, str]) -> dict:
        return {"variations": {"plural": {
            cat: {"stringUnit": {"state": st, "value": f"{cat} form"}} for cat, st in states.items()
        }}}

    def test_fully_translated_plural_is_not_a_gap(self):
        cat = {"strings": {"%lld days": {"localizations": {
            lang: self._plural({"one": "translated", "other": "translated"})
            for lang in ("de", "es", "fr", "pt-PT")
        }}}}
        out = self._summary(cat)
        for lang in ("de", "es", "fr", "pt-PT"):
            self.assertIn(f"{lang} missing=0", out)

    def test_polish_extra_plural_categories_are_not_penalised(self):
        """one/few/many/other is Polish being handled correctly, not five gaps."""
        cat = {"strings": {"%lld days": {"localizations": {
            "pl": self._plural({c: "translated" for c in ("one", "few", "many", "other")}),
        }}}}
        self.assertIn("pl missing=0", self._summary(cat))

    def test_partially_translated_plural_is_still_a_gap(self):
        """The fix must not over-correct: one untranslated category still counts."""
        cat = {"strings": {"%lld days": {"localizations": {
            "de": self._plural({"one": "translated", "other": "new"}),
        }}}}
        self.assertIn("de missing=1", self._summary(cat))

    def test_flat_string_unit_still_counted(self):
        """Non-plural entries keep working exactly as before."""
        cat = {"strings": {
            "Hello": {"localizations": {"de": {"stringUnit": {"state": "translated", "value": "Hallo"}}}},
            "Bye": {"localizations": {"de": {"stringUnit": {"state": "new", "value": ""}}}},
        }}
        self.assertIn("de missing=1", self._summary(cat))

    def test_should_translate_false_is_skipped(self):
        cat = {"strings": {"NOOP": {"shouldTranslate": False, "localizations": {}}}}
        self.assertIn("de missing=0", self._summary(cat))
