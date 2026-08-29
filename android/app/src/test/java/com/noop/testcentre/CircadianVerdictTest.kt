package com.noop.testcentre

import com.noop.analytics.CircadianEngine
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The body-clock verdict line. The card vanishing has two indistinguishable causes on screen — no
 * estimate at all (below the bucket or hour floor) versus an estimate marked unreadable (thin or flat
 * fit, which still draws its own card) — so the wording has to name WHICH floor is short.
 */
class CircadianVerdictTest {

    private fun verdict(buckets: Int, hours: Int, days: Int, amp: Double? = 0.5) =
        AndroidDiagnostics.circadianVerdict(buckets, hours, days, amp)

    /** Gates are reported in the order the pipeline applies them: the bucket floor short-circuits first. */
    @Test fun theBucketFloorIsReportedBeforeAnythingElse() {
        val v = verdict(buckets = 10, hours = 2, days = 1)
        assertTrue(v, v.startsWith("no estimate"))
        assertTrue(v, v.contains("10 hourly HR buckets") && v.contains("needs 24"))
    }

    @Test fun theHourFloorIsNamedWhenBucketsAreFine() {
        val v = verdict(buckets = 100, hours = 4, days = 9)
        assertTrue(v, v.startsWith("no estimate"))
        assertTrue(v, v.contains("4 of 24 local hours") && v.contains("needs 6"))
    }

    /**
     * A flat rhythm and a short history BOTH yield UNREADABLE from the engine, and the card still draws
     * for either — so the line must distinguish them or it explains nothing.
     */
    @Test fun aFlatRhythmIsDistinguishedFromAShortHistory() {
        val flat = verdict(buckets = 300, hours = 20, days = 20, amp = 0.02)
        assertTrue(flat, flat.startsWith("unreadable") && flat.contains("too flat"))
        val thin = verdict(buckets = 300, hours = 20, days = 3, amp = 0.5)
        assertTrue(thin, thin.startsWith("unreadable") && thin.contains("3 days observed"))
    }

    /** The readable tiers name the confidence the card will actually show. */
    @Test fun readableTiersMatchTheEnginesOwnThresholds() {
        val wide = verdict(buckets = 300, hours = 20, days = CircadianEngine.minDaysForFit)
        assertTrue(wide, wide.startsWith("wide"))
        val solid = verdict(buckets = 300, hours = 20, days = CircadianEngine.goodDaysForFit)
        assertTrue(solid, solid.startsWith("solid"))
    }

    /** An unmeasurable amplitude must not be read as a flat rhythm. */
    @Test fun anUnknownAmplitudeDoesNotReadAsFlat() {
        val v = verdict(buckets = 300, hours = 20, days = 20, amp = null)
        assertTrue(v, v.startsWith("solid"))
    }
}
