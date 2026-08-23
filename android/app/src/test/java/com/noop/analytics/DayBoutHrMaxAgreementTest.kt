package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1545: a workout and the day containing it must be scored against the SAME HRmax.
 *
 * `analyzeDay` computes `effMaxHR = maxHROverride ?: tanakaHRmax(age)` for the day's Effort, but used to
 * hand `WorkoutDetector.detect` only `maxHROverride`. With no override — the default — the detector fell
 * back to [StrainScorer.estimateHRmax], which returns `max(observed p99.5, Tanaka)`. So every bout was
 * measured against a HRmax at least as high as its own day's, and usually higher.
 *
 * A higher HRmax is a bigger reserve and therefore a SMALLER %HRR, so bouts were held to a STRICTER
 * standard than the day they sit inside. At age 30 / RHR 60 with an observed 195 bpm, a 125 bpm minute is
 * zone 1 for the day and zone 0 for the bout — it counts toward the day total and scores nothing in the
 * workout. That lands hardest at the 50% floor, which is the whole subject of #1545.
 *
 * Byte-parity twin of Swift `DayBoutHrMaxAgreementTests`.
 */
class DayBoutHrMaxAgreementTest {

    private val age = 30.0
    private val rhr = 60.0
    private val tanaka = StrainScorer.tanakaHRmax(age)   // 187 for age 30

    /** The arithmetic the fix is about, stated independently of the engine. */
    private fun zoneWeight(bpm: Double, hrmax: Double): Int {
        val pct = (bpm - rhr) / (hrmax - rhr) * 100.0
        return when {
            pct >= 90 -> 5; pct >= 80 -> 4; pct >= 70 -> 3; pct >= 60 -> 2; pct >= 50 -> 1
            else -> 0
        }
    }

    /**
     * The divergence, in the estimator itself: `estimateHRmax` never returns BELOW Tanaka, so the bout's
     * fallback HRmax is always >= the day's. This is why the bug is one-directional — bouts could only
     * ever be under-scored relative to their day, never over-scored.
     */
    @Test
    fun theBoutFallbackIsNeverBelowTheDaysTanaka() {
        for (observed in listOf(150.0, 185.0, 195.0, 210.0)) {
            val hist = List(700) { observed }
            val est = StrainScorer.estimateHRmax(hist, age).first
            assertTrue("observed=$observed gave $est, below Tanaka $tanaka", est >= tanaka - 1e-9)
        }
    }

    /**
     * The concrete split: the same heart rate is worth a zone to the day and nothing to the bout, purely
     * because the two used different HRmax values.
     */
    @Test
    fun theSameMinuteSplitsAcrossTheZoneFloor() {
        val observed = 195.0
        val boutMax = StrainScorer.estimateHRmax(List(700) { observed }, age).first
        assertEquals("fixture assumes the observed value wins", observed, boutMax, 1e-9)

        assertEquals("day scores it zone 1", 1, zoneWeight(125.0, tanaka))
        assertEquals("bout scored it zone 0 — the bug", 0, zoneWeight(125.0, boutMax))
    }

    /**
     * The fix, end to end — and it is a DETECTION change, not only a scoring one.
     *
     * A 138 bpm bout is 61.4% HRR against the day's Tanaka 187 (zone 2) but 57.8% against an observed 195
     * (zone 1). The detector's z2+ qualification gate needs half the bout in zone 2 or above, so before
     * the fix this workout was DROPPED — by a standard its own day never applied. It is now detected, and
     * carries the day's HRmax.
     */
    @Test
    fun theDaysHrMaxReachesDetectionAndScoring() {
        val res = AnalyticsEngine.analyzeDay(
            day = "2026-08-23",
            hr = dayWithAHardPeakAndABoundaryBout(),
            dayHr = dayWithAHardPeakAndABoundaryBout(),
            gravity = movingAllDay(),
            dayGravity = movingAllDay(),
            profile = UserProfile(age = age, sex = "male"),
        )
        assertTrue("the boundary bout should now be detected", res.workouts.isNotEmpty())
        for (w in res.workouts) {
            assertEquals(
                "every bout must carry the day's HRmax, not the observed estimate",
                tanaka, w.hrmax ?: -1.0, 1e-9,
            )
        }
    }

    /** An explicit override still wins — the fix must never override the user's own number. */
    @Test
    fun anExplicitOverrideStillWins() {
        val res = AnalyticsEngine.analyzeDay(
            day = "2026-08-23",
            hr = dayWithAHardPeakAndABoundaryBout(),
            dayHr = dayWithAHardPeakAndABoundaryBout(),
            gravity = movingAllDay(),
            dayGravity = movingAllDay(),
            profile = UserProfile(age = age, sex = "male"),
            maxHROverride = 175.0,
        )
        assertTrue(res.workouts.isNotEmpty())
        for (w in res.workouts) assertEquals(175.0, w.hrmax ?: -1.0, 1e-9)
    }

    // A day with: a brief hard effort (lifts the observed p99.5 above Tanaka), a long rest that sets a low
    // resting baseline, and a sustained bout sitting exactly between the two HRmax interpretations.
    private fun dayWithAHardPeakAndABoundaryBout(): List<HrSample> {
        val out = ArrayList<HrSample>(7200)
        fun run(from: Int, until: Int, bpm: Int) {
            for (t in from until until) out.add(HrSample("t", t.toLong(), bpm))
        }
        run(0, 600, 195)        // hard peak -> observed p99.5 = 195
        run(600, 2400, 60)      // rest -> 10th-percentile resting baseline stays 60
        run(2400, 6000, 138)    // the boundary bout: zone 2 on Tanaka, zone 1 on observed
        run(6000, 7200, 60)
        return out
    }

    // Motion must actually vary: intensity is the euclidean step between consecutive gravity samples and
    // has to clear motionThreshold (0.20) after smoothing, so a constant vector detects nothing.
    private fun movingAllDay(): List<GravitySample> =
        (0 until 7200).map {
            GravitySample("t", it.toLong(), x = if (it % 2 == 0) 0.9 else 0.5, y = 0.1, z = 0.1)
        }
}
