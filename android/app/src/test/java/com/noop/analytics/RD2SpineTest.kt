package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/RD2SpineTests.swift (RD2, PR #469).
 *
 * The readiness HRV/RHR baselines are folded through the shared Winsorized-EWMA spine
 * (Baselines.foldHistory) instead of a naive mean + sample SD, in the WINDOW-FOLD mode
 * (rejectHardOutliers = false). Hard-outlier rejection is right for RecoveryScorer's incremental
 * nightly fold but WRONG for a re-folded trailing window, where a recent sustained shift lands past
 * the young grace period and would be rejected as a run of "outliers". Winsorization (kept) still
 * damps single freak nights. Same fixtures and thresholds as the Swift test.
 */
class RD2SpineTest {

    // The spine capability itself: reject on (incremental) vs off (window-fold) -------------------

    @Test
    fun windowFoldAdaptsToSustainedShiftThatIncrementalRejects() {
        // 20 settled nights at 140 ms, then 10 recent nights at 85 ms (a real sustained shift). The
        // incremental fold (reject on) discards the recent block as >5σ outliers and stays anchored
        // high; the window fold (reject off) follows the shift down. This is the exact readiness
        // failure mode (device swap / supplement onset) the mode switch fixes.
        val vals: List<Double?> = List(20) { 140.0 } + List(10) { 85.0 }
        val rejectOn = Baselines.foldHistory(vals, Baselines.hrvCfg, rejectHardOutliers = true)
        val rejectOff = Baselines.foldHistory(vals, Baselines.hrvCfg, rejectHardOutliers = false)
        assertTrue("hard-reject keeps the stale high baseline", rejectOn.baseline > 130)
        assertTrue(
            "window-fold adapts meaningfully toward the recent sustained level",
            rejectOff.baseline < rejectOn.baseline - 10,
        )
    }

    @Test
    fun singleFreakNightIsDampedNotRejectedInWindowFold() {
        // One freak sensor night in an otherwise stable baseline. With reject OFF the freak is not
        // discarded — but Winsorization still CLAMPS it, so it barely moves the center. (Contrast the
        // sustained block above, which the same mode follows: single spike damped, sustained shift
        // adapted — the whole point of Winsor-without-reject.)
        val stable: List<Double?> = List(29) { 90.0 }
        val withFreak: List<Double?> = stable + listOf(180.0)
        val base0 = Baselines.foldHistory(stable, Baselines.hrvCfg, rejectHardOutliers = false)
        val base1 = Baselines.foldHistory(withFreak, Baselines.hrvCfg, rejectHardOutliers = false)
        assertTrue(
            "a single 2× freak night must be Winsor-damped, not swing the baseline",
            abs(base1.baseline - base0.baseline) < 8,
        )
    }

    // Readiness end-to-end (ln-space HRV, reject off) ---------------------------------------------

    private fun d(i: Int, hrv: Double?, rhr: Int?): DailyMetric = DailyMetric(
        deviceId = "test",
        day = "2024-03-%02d".format(i),
        restingHr = rhr,
        avgHrv = hrv,
        strain = 10.0,
    )

    @Test
    fun readinessAdaptsToRecentSustainedHRVShift() {
        // 12 old nights at 130 ms, then 18 recent nights settled at 85 ms (a sustained shift), today at
        // the new normal 85. It must NOT read BAD — the window fold adapts. Under the incremental
        // (reject-on) mode this exact case reads BAD (the recent block is rejected, baseline stuck at
        // 130), which is the readiness regression RD2 exists to prevent.
        val days = mutableListOf<DailyMetric>()
        for (i in 1..12) days.add(d(i, hrv = 130.0, rhr = 52))
        for (i in 13..30) days.add(d(i, hrv = 85.0, rhr = 52))
        days.add(d(31, hrv = 85.0, rhr = 52))   // today: the new normal
        val hrv = ReadinessEngine.evaluate(days).signals.firstOrNull { it.key == "hrv" }
        assertNotNull(hrv)
        assertNotEquals(
            "today at the recent sustained normal must not read BAD (the reject-mode failure)",
            ReadinessEngine.Flag.BAD, hrv!!.flag,
        )
    }

    @Test
    fun genuineLowStillFlagsAfterSpineAdoption() {
        // Regression: the spine must not blunt a real drop. Stable ~95 ms baseline, today a clear 68 ms.
        val days = mutableListOf<DailyMetric>()
        for (i in 1..30) days.add(d(i, hrv = if (i % 2 == 0) 97.0 else 93.0, rhr = 52))
        days.add(d(31, hrv = 68.0, rhr = 52))
        val hrv = ReadinessEngine.evaluate(days).signals.firstOrNull { it.key == "hrv" }
        assertEquals("a genuine ~28% HRV drop must still read BAD", ReadinessEngine.Flag.BAD, hrv?.flag)
    }
}
