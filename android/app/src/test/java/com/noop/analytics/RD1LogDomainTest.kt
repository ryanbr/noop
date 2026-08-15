package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/RD1LogDomainTests.swift (Wave 0 · RD1, PR #456).
 *
 * The readiness HRV signal is z-scored in the LOG domain (lnRMSSD), not raw ms. RMSSD is
 * right-skewed, so a symmetric z on raw ms over-weights the long upper tail; lnRMSSD is closer to
 * normal (Plews/Altini; the app's own HRVReadiness works this way). Observable consequence: the
 * baseline the signal reports is the GEOMETRIC mean (a typical night), not an arithmetic mean that a
 * few big-recovery nights inflate. RHR stays linear (it is ~normal). Same fixture and expected
 * evidence string as the Swift test.
 */
class RD1LogDomainTest {

    private fun d(i: Int, hrv: Double?, rhr: Int?): DailyMetric = DailyMetric(
        deviceId = "test",
        day = "2024-03-%02d".format(i),
        restingHr = rhr,
        avgHrv = hrv,
        strain = 10.0,
    )

    @Test
    fun hrvBaselineIsGeometricNotArithmetic() {
        // 20 nights at 42 ms + 8 big-recovery nights at 85 ms: arithmetic mean ≈ 54, geometric ≈ 51.
        val days = mutableListOf<DailyMetric>()
        for (i in 1..20) days.add(d(i, hrv = 42.0, rhr = if (i % 2 == 0) 53 else 51))
        for (i in 21..28) days.add(d(i, hrv = 85.0, rhr = if (i % 2 == 0) 53 else 51))
        days.add(d(29, hrv = 50.0, rhr = 52))   // today: a typical night

        val hrv = ReadinessEngine.evaluate(days).signals.first { it.key == "hrv" }
        // Log domain baselines against a GEOMETRIC center (49 ms), well below the arithmetic mean (54)
        // a raw-ms z would report. Under RD2 the center is the recency-weighted, Winsor-clamped EWMA
        // (Baselines spine, reject off): the 8 recent 85 ms nights nudge it up from the 42 ms cluster
        // but Winsorization caps their pull, so it lands at 49 — still geometric, not the tail-inflated
        // arithmetic 54. Byte-identical to the Swift RD1LogDomainTests value.
        assertEquals("50 vs 49 ms", hrv.evidence)
        // 50 sits at the typical night → neutral, read against a representative (not tail-inflated) baseline.
        assertEquals(ReadinessEngine.Flag.NEUTRAL, hrv.flag)
    }
}
