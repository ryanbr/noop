package com.noop.ui

import com.noop.analytics.AutoWorkoutDetector
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure dismissal-policy tests; no Android Context or SharedPreferences runtime required. */
class AutoWorkoutPrefsTest {

    private fun candidate(start: Long = 1_000L, end: Long = 2_000L) =
        AutoWorkoutDetector.DetectedWorkout(start, end, avgBpm = 130, peakBpm = 150, durationMin = 16)

    @Test fun cardDismissalRequiresTheExactPublishedToken() {
        assertTrue(
            AutoWorkoutPrefs.isDismissed(
                candidate(),
                legacyTokens = setOf("1000:2000"),
                detectedSpans = emptyList(),
            ),
        )
        assertFalse(
            AutoWorkoutPrefs.isDismissed(
                candidate(start = 990L, end = 2_015L),
                legacyTokens = setOf("1000:2000"),
                detectedSpans = emptyList(),
            ),
        )
    }

    @Test fun durableDetectedMarkerAlsoSuppressesSuggestion() {
        assertTrue(
            AutoWorkoutPrefs.isDismissed(
                candidate(),
                legacyTokens = emptySet(),
                detectedSpans = listOf(1_500L to 2_500L),
            ),
        )
    }

    @Test fun malformedAndDisjointDismissalsDoNotSuppressSuggestion() {
        assertFalse(
            AutoWorkoutPrefs.isDismissed(
                candidate(),
                legacyTokens = setOf("malformed", "1:not-a-number", "10:900"),
                detectedSpans = listOf(2_001L to 3_000L),
            ),
        )
    }

    @Test fun durableDetectedMarkerUsesHalfOpenOverlap() {
        assertFalse(
            "touching the candidate end is not an overlap",
            AutoWorkoutPrefs.isDismissed(
                candidate(),
                legacyTokens = emptySet(),
                detectedSpans = listOf(2_000L to 3_000L),
            ),
        )
        assertFalse(
            "touching the candidate start is not an overlap",
            AutoWorkoutPrefs.isDismissed(
                candidate(),
                legacyTokens = emptySet(),
                detectedSpans = listOf(500L to 1_000L),
            ),
        )
    }

    @Test fun pruneUsesNumericEndSuffixEvenWhenStartIsMalformed() {
        val now = 10_000_000L
        val tooOld = "not-a-start:${now - 30L * 86_400L - 1L}"
        val recent = "still-not-a-start:$now"
        val malformedEnd = "100:not-an-end"

        assertEquals(
            setOf(recent, malformedEnd),
            AutoWorkoutPrefs.prune(setOf(tooOld, recent, malformedEnd), now),
        )
    }
}
