"""Pin the actual writer key sets that make the single-scope computation PK safe.

This reads both product sources, so it belongs to the unfiltered core Tools suite.
A new producer/key requires an explicit scope decision instead of silently letting a
window stamp overwrite (and later delete) a standalone stamp for the same cell.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WINDOW_KEYS = {
    "recovery", "strain", "sleep_performance", "spo2_candidate", "hrv_rr_overcount",
    "rhr_primary_session", "rhr_primary_session_valid_samples", "rhr_primary_session_duration_s",
    "day_cycle_onset_ts",
}
SERIES_KEYS = {"fitness_age", "vo2max_est", "vitality", "body_age", "steps_est"}


class ScoreComputationScopesTest(unittest.TestCase):
    def test_actual_writer_keys_are_disjoint_on_both_platforms(self):
        for language, path, start, end in (
            ("Swift", "Strand/Data/IntelligenceEngine.swift", "var restPoints:", "try await store.persistComputedScores("),
            ("Kotlin", "android/app/src/main/java/com/noop/analytics/IntelligenceEngine.kt", "val restRows =", "private suspend fun persistFitnessVitalityAndSteps("),
        ):
            with self.subTest(language=language):
                source = (ROOT / path).read_text()
                self.assertEqual(1, source.count(start))
                self.assertEqual(1, source.count(end))
                before, window = source.split(start)
                window, after = window.split(end)
                # Constructors name keys before their value expression; no closing parenthesis
                # appears in the day/device arguments at these producer sites.
                pattern = r'(?:MetricPoint|MetricSeriesRow)\([^)]*?\bkey\s*[:=]\s*"([^"]+)"'
                window_keys = set(re.findall(pattern, window)) | {"day_cycle_onset_ts"}
                if language == "Swift":
                    window_keys |= set(re.findall(
                        r'ScoreInputProvenanceRow\([^)]*?\bkey:\s*"([^"]+)"', window))
                else:
                    persistence = (ROOT / "android/app/src/main/java/com/noop/analytics/IntelligencePersistence.kt").read_text()
                    window_keys |= set(re.findall(
                        r'ScoreInputProvenanceRow\(\s*computedId,\s*daily.day,\s*"([^"]+)"', persistence))
                series_keys = set(re.findall(pattern, before + after))
                self.assertFalse(window_keys & series_keys, "a computation cell must have one owning scope")
                self.assertEqual(WINDOW_KEYS, window_keys)
                self.assertEqual(SERIES_KEYS, series_keys)
                # Pin the dynamic onset key and the daily-score keys alongside the literal series.
                if language == "Swift":
                    cycle = (ROOT / "Strand/Data/DayCycleIntelligenceIntegration.swift").read_text()
                    self.assertIn('static let onsetKey = "day_cycle_onset_ts"', cycle)
                    self.assertIn('key: DayCycleIntelligenceIntegration.onsetKey', window)
                    daily = window
                    key_syntax = 'key: "{}"'
                else:
                    cycle = (ROOT / "android/app/src/main/java/com/noop/analytics/DayCycleIntelligenceIntegration.kt").read_text()
                    self.assertIn('const val ONSET_KEY = "day_cycle_onset_ts"', cycle)
                    daily = (ROOT / "android/app/src/main/java/com/noop/analytics/IntelligencePersistence.kt").read_text()
                    key_syntax = '"{}"'
                for key in ("recovery", "strain"):
                    self.assertIn(key_syntax.format(key), daily)


if __name__ == "__main__":
    unittest.main()
