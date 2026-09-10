#!/usr/bin/env python3
"""Focused zero-baseline localization guard for the phone Home/Today surfaces.

This intentionally does not use the repository-wide grandfathered baseline.  Once the
Home migration is complete, every finding in this source closure must stay at zero.
Run with::

    python3 Tools/test_home_i18n.py
"""

from __future__ import annotations

import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

import i18n_audit as audit


ROOT = Path(__file__).resolve().parents[1]

# The complete Android Today implementation plus the small Today-only helpers it calls.
# AppRoot is deliberately handled separately below: most of that file is the unrelated
# More/navigation UI, while only its Today tab and quick-action resources belong here.
ANDROID_HOME_FILES = {
    "android/app/src/main/java/com/noop/ui/TodayScreen.kt",
    "android/app/src/main/java/com/noop/ui/TodayDayNav.kt",
    "android/app/src/main/java/com/noop/ui/TodayLayoutPrefs.kt",
    "android/app/src/main/java/com/noop/ui/TodayMetricsLogic.kt",
    "android/app/src/main/java/com/noop/ui/TodayProvenance.kt",
    "android/app/src/main/java/com/noop/ui/TodayScoring.kt",
    "android/app/src/main/java/com/noop/ui/AutoWorkoutNudge.kt",
    "android/app/src/main/java/com/noop/ui/JournalReminder.kt",
    "android/app/src/main/java/com/noop/ui/CycleTrackerDialog.kt",
    "android/app/src/main/java/com/noop/ui/KeyMetricPrefs.kt",
    "android/app/src/main/java/com/noop/ui/DashboardCards.kt",
    "android/app/src/main/java/com/noop/analytics/ReadinessEngine.kt",
    "android/app/src/main/java/com/noop/analytics/StepsEstimateEngine.kt",
    "android/app/src/main/java/com/noop/analytics/RecoveryDrivers.kt",
}
ANDROID_SHELL_FILE = "android/app/src/main/java/com/noop/ui/AppRoot.kt"

# Both selectable Today implementations, their Today-only editor/metadata, the shared
# day picker that they render, and the iPhone shell/icon actions that enter Home.
APPLE_HOME_FILES = {
    "Strand/Screens/TodayView.swift",
    "Strand/Liquid/LiquidTodayView.swift",
    "Strand/Screens/TodayCustomizationSheet.swift",
    "Strand/Screens/TodayCustomizationMetadata.swift",
    "Packages/StrandDesign/Sources/StrandDesign/DayNavBar.swift",
    "StrandiOS/System/HomeScreenQuickActions.swift",
    "Strand/Screens/AutoWorkoutCard.swift",
    "Strand/Screens/JournalReminderCard.swift",
    "Strand/Screens/SkinTempCardsView.swift",
    "Strand/Screens/HealthAlertBanner.swift",
}
APPLE_SHELL_FILE = "StrandiOS/App/RootTabView.swift"

# RootTabView also owns the unrelated More tab.  Limit its Home contract to the
# Today tab label, the sheet opened from Today's + button, and that sheet's close
# affordance instead of treating every future RootTabView string as Home copy.
APPLE_HOME_SHELL_CATALOG_KEYS = {
    "Today", "Done", "QUICK ACTIONS", "Live HR", "Start workout", "Log journal", "Breathe",
}

# These helpers return display strings through variables, which scan_android cannot
# data-flow back from Text(variable).  Scan every literal in them conservatively.  The
# allowlist contains only persistence/source identifiers and date formats, never copy.
ANDROID_DISPLAY_HELPERS = {
    "android/app/src/main/java/com/noop/ui/TodayLayoutPrefs.kt",
    "android/app/src/main/java/com/noop/ui/TodayMetricsLogic.kt",
    "android/app/src/main/java/com/noop/ui/TodayProvenance.kt",
    "android/app/src/main/java/com/noop/ui/TodayScoring.kt",
}

# These producers feed strings into Home through fields/lambdas, so the general Android scanner cannot
# see the eventual Text(variable). Only stable wire ids, preference keys, units and format specs belong
# in the allowlist; every human phrase must become a semantic/resource contract.
ANDROID_INDIRECT_COPY_FILES = {
    "android/app/src/main/java/com/noop/analytics/ReadinessEngine.kt",
    "android/app/src/main/java/com/noop/analytics/StepsEstimateEngine.kt",
    "android/app/src/main/java/com/noop/ui/AutoWorkoutNudge.kt",
    "android/app/src/main/java/com/noop/ui/KeyMetricPrefs.kt",
    "android/app/src/main/java/com/noop/ui/DashboardCards.kt",
    "android/app/src/main/java/com/noop/analytics/RecoveryDrivers.kt",
}
ANDROID_INDIRECT_NON_UI_LITERALS = {
    # Engine keys, metric units and numeric format specs.
    "hrv", "rhr", "respRate", "acwr", "monotony", "ms", "bpm", "rpm", "%.1f",
    # Auto-workout source/wire values. Workout is the persisted generic sport tag, not rendered copy.
    "my-whoop", "Workout", "apple-health", "health-connect", "lifting", "autoDetect",
    # Stable KeyMetric raw values + preferences.
    "charge", "effort", "rest", "restingHr", "bloodOxygen", "respiratory", "steps",
    "weight", "calories", "today.keyMetrics", "today.keyMetricsDetailed",
    "today.keyMetricsWindowDays", ",",
    # Stable DashboardCard raw values + preference; units remain measurement metadata.
    "stress", "fitnessAge", "vo2max", "vitality", "skinTemp", "sleep", "hydration", "coupled",
    "coach",
    "today.dashboardCards", "yrs", "kcal", "",
}

# Confirmed runtime copy that reaches Today through variables, lambdas, model fields or accessibility
# aggregation. The normal Compose scanner cannot follow those producer paths, so pin every confirmed
# phrase until it has a resource/semantic contract. Wire ids and format strings are intentionally absent.
ANDROID_TODAY_RUNTIME_COPY = {
    "Today", "Yesterday", "day", "days",
    "Session running", "Session ended", "Start session",
    "Guarding — silence means you're on track.", "See the summary of your last session.",
    "Strap-guided effort session. It only buzzes when you drift off today's band.", "BETA",
    "Building your baseline", "Charge, Effort and Rest become personal after a few nights of wear.",
    "Live now. Your scores are building.", "Charge, Effort and Rest build over your next few nights of wear.",
    "Cards with no value yet show a dash.", "SOLID", "BUILDING", "CALIBRATING",
    "5-minute average | selected day", "5-minute average | since midnight",
    "24-hour heart rate", "Still", "Walking", "Running",
    "Good morning", "Good afternoon", "Good evening", "No Data", "Calibrating",
    "7-day trend", "14-day trend", "30-day trend", "1 week", "2 weeks", "1 month",
}
ANDROID_HELPER_NON_UI_LITERALS = {
    # TodayLayoutPrefs stable backup/persistence wire values.
    "hero", "liveSession", "synthesis", "keyMetrics", "workouts", "heartRate",
    "recoveryVitals", "yourCards", "menstrualCycle", "journal", "addedCards",
    "today.sectionOrder", "today.hiddenSections",
    # TodayScoring parse/default formats.
    "9999-12-31", "d MMM", "24h", "12h", "6h", "3h", "1h",
    "<1m", "${secs / 60}m", "${secs / 3600}h", "${secs / 86_400}d",
    # TodayProvenance source ids and metric dictionary keys.
    "-noop", "recovery", "strain", "sleep_performance", "oura-import", "oura-api",
    "fitbit-import", "garmin-import", "xiaomi-band",
}

# AppRoot's Home-owned shell strings are resource-backed: the visible Today bottom-tab
# label and the four actions opened from Today's + button.  Do not gate unrelated AppRoot
# findings (for example the More-page expanded/collapsed accessibility state).
ANDROID_HOME_SHELL_RESOURCES = {
    "nav_today", "action_live_hr", "action_start_workout", "action_log_journal",
    "action_breathe",
}

R_STRING = re.compile(r"\bR\.string\.([A-Za-z_][A-Za-z0-9_]*)")
SWIFT_LOCALIZED_CALL = re.compile(r"\b(?:String\s*\(\s*localized:|LocalizedStringKey\s*\()\s*\"")


def _format_findings(rows: list[tuple[str, int, str]]) -> str:
    return "\n".join(f"{path}:{line}: {literal!r}" for path, line, literal in rows)


def _all_kotlin_literals(path: Path) -> list[tuple[int, str]]:
    """All non-comment string literals, using the audit's template-aware lexer."""
    text = audit._mask_comments(path.read_text(encoding="utf-8"))
    result: list[tuple[int, str]] = []
    i = 0
    while i < len(text):
        if text[i] != '"':
            i += 1
            continue
        end = audit._skip_string_literal(text, i)
        result.append((text.count("\n", 0, i) + 1, text[i + 1:end - 1]))
        i = end
    return result


def _is_helper_copy(literal: str) -> bool:
    """Stricter than the general audit for display-producing helper files.

    Lower-case one-word values such as ``latest``/``night`` are normally
    indistinguishable from ids, but in this tiny closure the real ids are all
    enumerated in ANDROID_HELPER_NON_UI_LITERALS, so they must be gated too.
    """
    return bool(re.search(r"[A-Za-z]", literal)) and not audit.PURE_FORMAT_SPEC.fullmatch(literal)


def _apple_catalog_for(path: str) -> Path:
    if path.startswith("Packages/StrandDesign/"):
        return ROOT / "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings"
    return ROOT / "Strand/Resources/Localizable.xcstrings"


def _localized_swift_literals(path: Path) -> set[str]:
    """Catalog-backed literals used by SwiftUI or explicit String(localized:)."""
    text = path.read_text(encoding="utf-8")
    literals = {literal for _, literal in audit.swift_string_literals(text)}
    for match in SWIFT_LOCALIZED_CALL.finditer(text):
        quote = match.end() - 1
        end = audit._skip_swift_string_literal(text, quote)
        literals.add(text[quote + 1:end - 1])
    return {literal for literal in literals if audit.is_probably_ui_text(literal)}


def _android_resource_names(path: Path) -> set[str]:
    return set(R_STRING.findall(audit._mask_comments(path.read_text(encoding="utf-8"))))


class HomeLocalizationTest(unittest.TestCase):
    maxDiff = None

    def test_android_home_has_no_audit_findings(self) -> None:
        findings = [row for row in audit.scan_android() if row[0] in ANDROID_HOME_FILES]
        self.assertEqual([], findings, "Unlocalized Android Home UI:\n" + _format_findings(findings))

    def test_android_display_helpers_have_no_raw_ui_copy(self) -> None:
        findings: list[tuple[str, int, str]] = []
        for relative in sorted(ANDROID_DISPLAY_HELPERS):
            for line, literal in _all_kotlin_literals(ROOT / relative):
                if literal in ANDROID_HELPER_NON_UI_LITERALS:
                    continue
                if _is_helper_copy(literal):
                    findings.append((relative, line, literal))
        self.assertEqual([], findings, "Raw Android Home helper copy:\n" + _format_findings(findings))

    def test_android_indirect_home_producers_have_no_raw_ui_copy(self) -> None:
        findings: list[tuple[str, int, str]] = []
        for relative in sorted(ANDROID_INDIRECT_COPY_FILES):
            for line, literal in _all_kotlin_literals(ROOT / relative):
                if literal in ANDROID_INDIRECT_NON_UI_LITERALS:
                    continue
                if _is_helper_copy(literal):
                    findings.append((relative, line, literal))
        self.assertEqual([], findings, "Raw indirect Android Home copy:\n" + _format_findings(findings))

    def test_android_today_runtime_producer_copy_is_resource_backed(self) -> None:
        relative = "android/app/src/main/java/com/noop/ui/TodayScreen.kt"
        findings = [
            (relative, line, literal)
            for line, literal in _all_kotlin_literals(ROOT / relative)
            if literal in ANDROID_TODAY_RUNTIME_COPY
        ]
        self.assertEqual([], findings, "Raw Today runtime producer copy:\n" + _format_findings(findings))

    def test_android_score_section_label_is_resolved_at_ui_boundary(self) -> None:
        relative = "android/app/src/main/java/com/noop/ui/ScoringGuideScreen.kt"
        source = audit._mask_comments((ROOT / relative).read_text(encoding="utf-8"))
        self.assertNotRegex(source, r"val\s+label\s*:\s*String", "ScoreSection must expose a resource contract")

    def test_android_home_score_labels_and_explain_copy_are_resource_backed(self) -> None:
        today_relative = "android/app/src/main/java/com/noop/ui/TodayScreen.kt"
        today = audit._mask_comments((ROOT / today_relative).read_text(encoding="utf-8"))
        self.assertNotIn("domain.label", today, "Home score names must be resolved from Android resources")

        guide_relative = "android/app/src/main/java/com/noop/ui/ScoringGuideScreen.kt"
        findings = [
            (guide_relative, line, literal)
            for line, literal in _all_kotlin_literals(ROOT / guide_relative)
            if _is_helper_copy(literal)
            and literal not in {
                "${(sampleFraction * 100).roundToInt()}",
                "noop_scoring_guide_prefs",
                "scoringGuideCardSeen",
            }
        ]
        self.assertEqual([], findings, "Raw Android score-explainer copy:\n" + _format_findings(findings))

    def test_android_home_score_labels_and_empty_states_fit_localized_copy(self) -> None:
        source = (ROOT / "android/app/src/main/java/com/noop/ui/TodayScreen.kt").read_text(encoding="utf-8")
        self.assertIn("text = domainLabel.uppercase()", source)
        self.assertIn(".padding(start = Metrics.space2, end = Metrics.space18)", source)
        self.assertIn("minScale = 0.7f", source)
        self.assertIn("private fun RingNoData(diameter: Dp)", source)
        self.assertIn("maxLines = 2", source)
        self.assertIn("overflow = TextOverflow.Clip", source)
        self.assertNotIn("Text(domainLabel.uppercase()", source)
        self.assertNotIn("private fun RingNoData()", source)

    def test_android_section_header_trailing_copy_does_not_squeeze_title(self) -> None:
        source = (ROOT / "android/app/src/main/java/com/noop/ui/Components.kt").read_text(encoding="utf-8")
        section_header = source.split("fun SectionHeader(", 1)[1].split("// MARK: - StrandTone", 1)[0]
        self.assertIn("if (overline != null || trailing != null)", section_header)
        self.assertIn("Text(title, style = NoopType.title2", section_header)
        self.assertLess(section_header.index("if (trailing != null)"), section_header.index("Text(title"))

    def test_android_today_source_counts_use_two_plural_resources(self) -> None:
        relative = "android/app/src/main/java/com/noop/ui/TodayScreen.kt"
        source = audit._mask_comments((ROOT / relative).read_text(encoding="utf-8"))
        self.assertIn("R.plurals.today_source_days", source)
        self.assertIn("R.plurals.today_source_workouts", source)
        self.assertNotIn("R.string.today_source_counts", source)

    def test_android_analytics_stays_free_of_ui_resources(self) -> None:
        source = (ROOT / "android/app/src/main/java/com/noop/analytics/ReadinessEngine.kt").read_text(encoding="utf-8")
        self.assertNotIn("com.noop.R", source)
        self.assertNotIn("androidx.annotation.StringRes", source)
        self.assertIn("enum class Copy", source)

    def test_android_english_home_contract_preserves_head_semantics(self) -> None:
        root = ET.parse(ROOT / "android/app/src/main/res/values/strings.xml").getroot()
        strings = {node.attrib["name"]: (node.text or "").replace("\\'", "'") for node in root.findall("string")}
        expected = {
            "today_card_hrv": "HRV", "today_card_hrv_subtitle": "Heart-rate variability",
            "today_card_resting_hr": "Resting HR", "today_card_resting_hr_subtitle": "Resting heart rate",
            "today_card_respiratory": "Respiratory", "today_card_respiratory_subtitle": "Breaths per minute",
            "today_card_steps": "Steps", "today_card_steps_subtitle": "Today",
            "today_card_stress": "Stress", "today_card_stress_subtitle": "Autonomic load",
            "today_card_fitness_age": "Fitness Age", "today_card_fitness_age_subtitle": "Updated weekly",
            "today_card_vo2max": "VO₂ Max", "today_card_vo2max_subtitle": "Estimated, updated weekly",
            "today_card_vitality": "Vitality", "today_card_vitality_subtitle": "Wellness score",
            "today_card_blood_oxygen": "Blood Oxygen", "today_card_blood_oxygen_subtitle": "Blood oxygen",
            "today_card_skin_temp": "Skin Temp", "today_card_skin_temp_subtitle": "Skin temperature",
            "today_card_sleep": "Sleep", "today_card_sleep_subtitle": "Last night",
            "today_card_calories": "Calories", "today_card_calories_subtitle": "Active energy",
            "today_card_hydration": "Hydration", "today_card_hydration_subtitle": "Today's fluid",
            "today_card_coupled": "Coupled view",
            "today_card_coupled_subtitle": "Recovery, strain and sleep in one glance",
            "today_readiness_wear_for_nights": "Wear the strap for a few nights and your readiness read will appear here.",
            "today_readiness_hrv_good": "above your baseline - well recovered",
            "today_readiness_normal_range": "in your normal range",
            "today_readiness_hrv_watch": "a touch below baseline",
            "today_readiness_hrv_bad": "suppressed - a sign of autonomic fatigue",
            "today_readiness_rhr_good": "at or below baseline",
            "today_readiness_rhr_watch": "running a little high",
            "today_readiness_rhr_bad": "elevated - overtraining or illness can do this",
            "today_readiness_resp_bad": "up vs baseline - sometimes an early sign of getting sick",
            "today_readiness_resp_watch": "slightly raised vs baseline",
            "today_readiness_monotony_watch": "low - similar strain every day raises strain/illness risk",
            "today_readiness_load_ramping_down": "ramping down (acute:chronic %1$s) - room to build",
            "today_readiness_load_sweet_spot": "in the sweet spot (acute:chronic %1$s)",
            "today_readiness_load_building_fast": "building fast (acute:chronic %1$s) - watch fatigue",
            "today_readiness_load_spiking": "spiking (acute:chronic %1$s) - higher injury risk",
            "today_readiness_more_nights": "A few more nights of data and your readiness read will sharpen.",
            "today_readiness_run_down_summary": "Several signals are down at once. Treat today as recovery - easy movement, real sleep tonight.",
            "today_readiness_strained_summary": "One of your signals is flagging. You can train, but keep it controlled and bank the recovery.",
            "today_readiness_primed_summary": "Your signals are aligned and your load is supported. A harder session is well backed today.",
            "today_readiness_balanced_summary": "Nothing's flagging. Train to feel - your body's holding steady.",
            "today_readiness_evidence_monotony": "monotony %1$s",
        }
        self.assertEqual({}, {key: (strings.get(key), value) for key, value in expected.items() if strings.get(key) != value})

    def test_android_today_chrome_and_click_labels_are_resource_backed(self) -> None:
        relative = "android/app/src/main/java/com/noop/ui/TodayScreen.kt"
        source = audit._mask_comments((ROOT / relative).read_text(encoding="utf-8"))
        patterns = {
            "raw SectionHeader/Overline": re.compile(r"\b(?:SectionHeader|Overline)\s*\(\s*\""),
            "raw onClickLabel": re.compile(r"\bonClickLabel\s*=\s*\""),
        }
        findings = []
        for kind, pattern in patterns.items():
            findings.extend(
                (relative, source.count("\n", 0, match.start()) + 1, kind)
                for match in pattern.finditer(source)
            )
        self.assertEqual([], findings, "Raw Today chrome/a11y copy:\n" + _format_findings(findings))

    def test_android_home_display_formatting_is_not_pinned_to_us_locale(self) -> None:
        display_files = ANDROID_INDIRECT_COPY_FILES | ANDROID_DISPLAY_HELPERS | {
            "android/app/src/main/java/com/noop/ui/TodayScreen.kt",
        }
        findings = []
        for relative in sorted(display_files):
            source = audit._mask_comments((ROOT / relative).read_text(encoding="utf-8"))
            findings.extend(
                (relative, source.count("\n", 0, match.start()) + 1, "Locale.US")
                for match in re.finditer(r"\b(?:java\.util\.)?Locale\.US\b", source)
            )
        self.assertEqual([], findings, "US-pinned Android Home display formatting:\n" + _format_findings(findings))

    def test_android_source_joiner_preserves_spaces_through_aapt(self) -> None:
        root = ET.parse(ROOT / "android/app/src/main/res/values/strings.xml").getroot()
        node = next(n for n in root.findall("string") if n.attrib.get("name") == "today_source_joiner")
        self.assertEqual('" + "', node.text, "Quote source_joiner so aapt preserves both spaces")

    def test_android_home_resources_cover_focus_locales(self) -> None:
        used = set(ANDROID_HOME_SHELL_RESOURCES)
        for relative in ANDROID_HOME_FILES:
            used.update(_android_resource_names(ROOT / relative))

        paths = {"en": ROOT / "android/app/src/main/res/values/strings.xml"}
        paths.update({
            lang: ROOT / f"android/app/src/main/res/{directory}/strings.xml"
            for lang, directory in audit.ANDROID_LOCALE_DIRS.items()
        })
        missing: list[str] = []
        for lang, path in paths.items():
            names = {node.attrib["name"] for node in ET.parse(path).getroot() if node.tag in {"string", "plurals"}}
            missing.extend(f"{lang}: {name}" for name in sorted(used - names))
        self.assertEqual([], missing, "Missing Android Home resources:\n" + "\n".join(missing))

    def test_android_home_locale_context_values_are_natural_and_complete(self) -> None:
        expected = {
            "pl": {
                "l10n_today_screen_no_cardio_load_yet_effort_builds_e952006c":
                    "Nie ma jeszcze obciążenia kardio. Wysiłek zwiększa się, gdy tętno osiągnie strefę wysiłku (około 50% rezerwy tętna). Spokojny dzień szczerze odczytuje się w pobliżu zera.",
            },
            "zh": {
                "l10n_today_screen_edit_key_metrics_f95e61a4": "编辑关键指标",
                "l10n_today_screen_no_new_nights_from_your_strap_for_stale_days_8863bcfe":
                    "你的手环已有 %1$d 天没有记录到新的夜间数据。请检查它是否已连接并正在保存数据。",
            },
            "pt-rPT": {"l10n_today_screen_synthesis_876bc749": "SÍNTESE"},
            "es": {"l10n_today_screen_unitformatter_effortdisplay_strain_effortscale_effort_53dbd951": "%1$s Esfuerzo"},
        }
        mismatches = {}
        for directory, locale_values in expected.items():
            root = ET.parse(ROOT / f"android/app/src/main/res/values-{directory}/strings.xml").getroot()
            strings = {node.attrib["name"]: node.text or "" for node in root.findall("string")}
            for key, value in locale_values.items():
                if strings.get(key) != value:
                    mismatches[f"{directory}:{key}"] = (strings.get(key), value)
        self.assertEqual({}, mismatches)

    def test_apple_home_has_no_audit_findings(self) -> None:
        findings, _ = audit.scan_ios()
        scoped = [row for row in findings if row[0] in APPLE_HOME_FILES]
        self.assertEqual([], scoped, "Unlocalized Apple Home UI:\n" + _format_findings(scoped))

    def test_apple_day_nav_dynamic_date_avoids_multiline_interpolation(self) -> None:
        source = (ROOT / "Packages/StrandDesign/Sources/StrandDesign/DayNavBar.swift").read_text(encoding="utf-8")
        self.assertIn("let formattedDay = selectedDay.formatted(", source)
        self.assertIn("return LocalizedStringKey(formattedDay)", source)
        self.assertNotIn('return "\\(selectedDay.formatted(', source)

    def test_apple_charge_driver_verdicts_are_complete_catalog_keys(self) -> None:
        source = (ROOT / "Packages/StrandAnalytics/Sources/StrandAnalytics/ChargeDrivers.swift").read_text(
            encoding="utf-8"
        )
        verdict_block = source.split("// MARK: - Plain-English verdicts", 1)[1].split(
            "static func skinTempDevText", 1
        )[0]
        verdicts = set(re.findall(r'(?:return|\?|:)\s*"([^"]+)"', verdict_block))
        # Thirteen return paths currently collapse to twelve unique keys because several helpers share
        # "at baseline". Pin the unique-key set size so syntax changes cannot silently evade extraction.
        self.assertEqual(12, len(verdicts), "Verdict extraction changed; review the catalog contract")

        catalog = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")
        missing = []
        for verdict in sorted(verdicts):
            entry = audit.swift_catalog_lookup(catalog, verdict)
            if entry is None:
                missing.append(f"all: {verdict!r} absent from catalog")
                continue
            for lang in audit.LANGS:
                if not audit._is_translated(entry, lang):
                    missing.append(f"{lang}: {verdict!r}")
        self.assertEqual([], missing, "Missing Charge-driver verdict translations:\n" + "\n".join(missing))

    def test_apple_home_catalog_entries_cover_focus_locales(self) -> None:
        missing: list[str] = []
        catalogs: dict[Path, dict] = {}
        for relative in sorted(APPLE_HOME_FILES):
            catalog_path = _apple_catalog_for(relative)
            catalog = catalogs.setdefault(catalog_path, audit.load_catalog(catalog_path))
            for literal in sorted(_localized_swift_literals(ROOT / relative)):
                entry = audit.swift_catalog_lookup(catalog, literal)
                if entry is None:
                    # The source-finding test reports this with a useful line number.
                    continue
                for lang in audit.LANGS:
                    if not audit._is_translated(entry, lang):
                        missing.append(f"{relative}: {lang}: {literal!r}")

        shell_catalog_path = _apple_catalog_for(APPLE_SHELL_FILE)
        shell_catalog = catalogs.setdefault(shell_catalog_path, audit.load_catalog(shell_catalog_path))
        for literal in sorted(APPLE_HOME_SHELL_CATALOG_KEYS):
            entry = audit.swift_catalog_lookup(shell_catalog, literal)
            if entry is None:
                missing.append(f"{APPLE_SHELL_FILE}: all: {literal!r} absent from catalog")
                continue
            for lang in audit.LANGS:
                if not audit._is_translated(entry, lang):
                    missing.append(f"{APPLE_SHELL_FILE}: {lang}: {literal!r}")
        self.assertEqual([], missing, "Missing Apple Home catalog translations:\n" + "\n".join(missing))

    def test_apple_skin_temp_dynamic_copy_uses_swift_interpolation(self) -> None:
        source = (ROOT / "Strand/Screens/SkinTempCardsView.swift").read_text(encoding="utf-8")
        for argument in ("hours", "signals", "reasons"):
            self.assertIn(
                rf"\({argument})",
                source,
                f"Skin-temperature localized copy must interpolate {argument} with Swift syntax",
            )

    def test_apple_whoop_brand_and_tint_are_locale_independent(self) -> None:
        source = (ROOT / "Strand/Screens/TodayView.swift").read_text(encoding="utf-8")
        catalog = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")
        self.assertEqual("WHOOP", catalog["strings"]["Whoop"]["localizations"]["pt-PT"]["stringUnit"]["value"])
        self.assertIn('private static let whoopBrandName = "WHOOP"', source)

        tint_start = source.index("private func provenanceTint")
        tint_end = source.index("// MARK: Apple Watch provenance", tint_start)
        self.assertNotIn("provenanceLabel(", source[tint_start:tint_end])

    def test_apple_liquid_runtime_copy_and_pt_terms_are_localized(self) -> None:
        source = (ROOT / "Strand/Liquid/LiquidTodayView.swift").read_text(encoding="utf-8")
        self.assertIn(
            'private var stressText: String { stress.map { String(Int($0.rounded())) } ?? String(localized: "Calibrating") }',
            source,
        )
        self.assertIn('return "\\(base) · \\(String(localized: \"Charging\"))"', source)

        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        expected = {
            "Push": "Avançar",
            "SYNTHESIS": "SÍNTESE",
            "Still": "Parado",
        }
        for key, value in expected.items():
            self.assertEqual(value, strings[key]["localizations"]["pt-PT"]["stringUnit"]["value"])

    def test_apple_home_semantic_display_contracts(self) -> None:
        app_model = (ROOT / "Strand/App/AppModel.swift").read_text(encoding="utf-8")
        illness = (ROOT / "Packages/StrandAnalytics/Sources/StrandAnalytics/IllnessSignalEngine.swift").read_text(encoding="utf-8")
        readiness = (ROOT / "Packages/StrandAnalytics/Sources/StrandAnalytics/ReadinessEngine.swift").read_text(encoding="utf-8")
        today = (ROOT / "Strand/Screens/TodayView.swift").read_text(encoding="utf-8")

        self.assertIn("public enum Message", illness)
        self.assertIn('suppressedBy.append("a hard or late workout")', illness)
        self.assertIn("suppressionReasons.append(.hardOrLateWorkout)", illness)
        self.assertNotIn('result.copy.contains("numbers agree")', (ROOT / "Strand/Screens/SkinTempCardsView.swift").read_text(encoding="utf-8"))
        self.assertIn('String(localized: "RHR +\\(delta)")', app_model)
        self.assertIn('String(localized: "HRV −\\(percent)%")', app_model)
        # 240c48ae (#1671): the label now carries the reader's unit via UnitFormatter.skinTempSignalPhrase,
        # so the sign and the hardcoded °C moved out of the localized literal.
        self.assertIn('String(localized: "Skin temperature \\(temperature)")', app_model)
        self.assertIn('String(localized: "Respiration up")', app_model)

        self.assertIn("public enum Evidence", readiness)
        self.assertIn("readinessEvidenceText", today)
        self.assertIn("readinessDetailText", today)
        self.assertIn('String(format: "%.\\(decimals)f", locale: AppLanguage.activeLocale, value)', today)
        self.assertNotIn("if let evidence = s.evidence", today)
        self.assertNotIn("LocalizedStringKey(s.detail)", today)

        self.assertIn("badge: Self.whoopBrandName", today)
        self.assertIn('case .nutritionCsv: return String(localized: "Nutrition")', today)
        self.assertIn('case .localCache: return String(localized: "Cached")', today)

        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        for key in (
            "RHR +%lld", "HRV −%lld%%", "Skin temperature %@", "Respiration up",
            "%@ vs %@ %@", "7d %@ / 28d %@", "monotony %@",
        ):
            self.assertIn(key, strings)
            for lang in audit.LANGS:
                self.assertTrue(audit._is_translated(strings[key], lang), f"{lang}: {key}")

    def test_apple_pt_home_terms_are_context_correct(self) -> None:
        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        expected = {
            "Strap battery": "Bateria da pulseira",
            "Needs the strap": "Requer a pulseira",
            "Run down": "Esgotado",
            "Rest HR": "FC repouso",
            "Resting HR": "FC em repouso",
            "Your cards": "Os teus cartões",
            "~%lldh left": "Faltam ~%lld h",
            "%lld days · %lld sleeps": "%1$lld dias · %2$lld noites de sono",
        }
        for key, value in expected.items():
            self.assertEqual(value, strings[key]["localizations"]["pt-PT"]["stringUnit"]["value"])

    def test_apple_home_banner_and_suppression_contract_are_semantic(self) -> None:
        app_model = (ROOT / "Strand/App/AppModel.swift").read_text(encoding="utf-8")
        banner = (ROOT / "Strand/Screens/HealthAlertBanner.swift").read_text(encoding="utf-8")
        illness = (ROOT / "Packages/StrandAnalytics/Sources/StrandAnalytics/IllnessSignalEngine.swift").read_text(encoding="utf-8")

        self.assertIn("struct HealthAlert: Equatable", app_model)
        self.assertIn("let message: IllnessSignalEngine.Message", app_model)
        self.assertIn("@Published var healthAlert: HealthAlert?", app_model)
        self.assertNotIn("? result.copy : nil", app_model)
        self.assertIn("localizedHealthAlertCopy", banner)
        self.assertNotIn("Text(alert)", banner)
        self.assertIn('suppressedBy.append("a hard or late workout")', illness)
        self.assertIn("public enum SuppressionReason", illness)
        self.assertIn("public let suppressionReasons: [SuppressionReason]", illness)

    def test_apple_de_score_glossary_preserves_physiology_terms(self) -> None:
        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        values = [
            entry.get("localizations", {}).get("de", {}).get("stringUnit", {}).get("value", "")
            for entry in strings.values()
        ]
        joined = "\n".join(values)
        self.assertNotIn("Erholungherz", joined)
        self.assertNotIn("Erholungqualität", joined)
        self.assertNotIn("Erholung- und Live-Herzfrequenz", joined)
        for key, expected in {
            "Charge": "Energie",
            "Effort": "Belastung",
            "Rest": "Erholung",
            "How Rest is calculated": "So wird Erholung berechnet",
        }.items():
            self.assertEqual(expected, strings[key]["localizations"]["de"]["stringUnit"]["value"])

    def test_apple_home_count_catalogs_have_real_focus_plural_variations(self) -> None:
        today = (ROOT / "Strand/Screens/TodayView.swift").read_text(encoding="utf-8")
        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        self.assertNotIn('String(localized: "\\(repo.days.count) days · \\(repo.sleeps.count) sleeps")', today)
        self.assertIn("localizedDayCount", today)
        self.assertIn("localizedSleepCount", today)
        self.assertIn("localizedWorkoutCount", today)
        for key in ("%lld days", "%lld sleeps", "%lld workouts"):
            for lang in ("en", *audit.LANGS, "it"):
                localization = strings[key].get("localizations", {}).get(lang, {})
                plural = localization.get("variations", {}).get("plural", {})
                self.assertIn("one", plural, f"{lang}: {key} missing singular")
                self.assertIn("other", plural, f"{lang}: {key} missing plural")

    def test_apple_illness_messages_are_not_portuguese_in_other_locales(self) -> None:
        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        keys = (
            "Your body looks strained. Signals up: %@. No alcohol or travel was logged, so consider taking it easy. On-device estimate, not a diagnosis.",
            "You logged feeling unwell, and your signals agree. Take it easy today. On-device estimate, not a diagnosis.",
            "You logged feeling unwell. Take it easy today. On-device estimate, not a diagnosis.",
            "Some signals are up, but you logged %@. That is the more likely explanation. On-device estimate, not a diagnosis.",
            "A few signals are mildly up: %@. Nothing alarming, but a calmer day may help. On-device estimate, not a diagnosis.",
            "Still learning your baseline and keeping an eye on your signals.",
            "Nothing notable. Your signals look like their normal range.",
        )
        for key in keys:
            localizations = strings[key]["localizations"]
            pt = localizations["pt-PT"]["stringUnit"]["value"]
            for lang in ("it", "pl", "ru", "zh-Hans", "zh-Hant"):
                self.assertNotEqual(pt, localizations[lang]["stringUnit"]["value"], f"{lang}: {key}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
