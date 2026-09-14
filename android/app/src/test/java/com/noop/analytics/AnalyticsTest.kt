package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AnalyticsTest {

    // --- Hrv.rmssd ----------------------------------------------------------

    @Test
    fun rmssd_knownVector() {
        // rr = [800, 810, 790, 805, 795]
        // diffs = [10, -20, 15, -10] -> squares = [100, 400, 225, 100]
        // sum = 825, n = 4, mean = 206.25, sqrt(206.25) = 14.361406616...
        val rr = listOf(800, 810, 790, 805, 795)
        assertEquals(14.361406616, Hrv.rmssd(rr), 1e-6)
    }

    @Test
    fun rmssd_constantIntervalsIsZero() {
        assertEquals(0.0, Hrv.rmssd(listOf(1000, 1000, 1000)), 1e-12)
    }

    @Test
    fun rmssd_tooFewSamplesIsZero() {
        assertEquals(0.0, Hrv.rmssd(emptyList()), 1e-12)
        assertEquals(0.0, Hrv.rmssd(listOf(1000)), 1e-12)
    }

    @Test
    fun rmssd_twoSamples() {
        // diff = 50 -> square = 2500 -> mean = 2500 -> sqrt = 50
        assertEquals(50.0, Hrv.rmssd(listOf(900, 950)), 1e-9)
    }

    // --- Zones --------------------------------------------------------------

    @Test
    fun zone_ladder() {
        val max = 190
        assertEquals(5, Zones.zone((max * 0.95).toInt(), max))  // 180 -> 0.947 -> z5
        assertEquals(4, Zones.zone((max * 0.82).toInt(), max))  // 155 -> 0.815 -> z4
        assertEquals(3, Zones.zone((max * 0.72).toInt(), max))  // 136 -> 0.715 -> z3
        assertEquals(2, Zones.zone((max * 0.62).toInt(), max))  // 117 -> 0.615 -> z2
        assertEquals(1, Zones.zone((max * 0.50).toInt(), max))  // 95  -> 0.5   -> z1
    }

    @Test
    fun zone_exactBoundaries() {
        // hrMax = 100 makes pct == hr/100 exactly.
        assertEquals(5, Zones.zone(90, 100))
        assertEquals(4, Zones.zone(80, 100))
        assertEquals(3, Zones.zone(70, 100))
        assertEquals(2, Zones.zone(60, 100))
        assertEquals(1, Zones.zone(59, 100))
    }

    @Test
    fun zone_invalidMaxFallsBackToZoneOne() {
        assertEquals(1, Zones.zone(120, 0))
        assertEquals(1, Zones.zone(120, -10))
    }

    @Test
    fun hrMaxTanaka_roundsCorrectly() {
        // 208 - 0.7*30 = 187.0 -> 187
        assertEquals(187, Zones.hrMaxTanaka(30))
        // 208 - 0.7*25 = 190.5 -> 191 (round half up)
        assertEquals(191, Zones.hrMaxTanaka(25))
        // 208 - 0.7*45 = 176.5 -> 177
        assertEquals(177, Zones.hrMaxTanaka(45))
    }

    // --- IllnessWatch -------------------------------------------------------

    private fun day(
        d: String,
        restingHr: Int? = null,
        avgHrv: Double? = null,
        skinTempDevC: Double? = null,
        respRateBpm: Double? = null,
    ): DailyMetric = DailyMetric(
        deviceId = "test",
        day = d,
        restingHr = restingHr,
        avgHrv = avgHrv,
        skinTempDevC = skinTempDevC,
        respRateBpm = respRateBpm,
    )

    @Test
    fun illness_tooFewDaysReturnsNull() {
        val days = (0 until 10).map { day("2026-01-%02d".format(it + 1), restingHr = 50, avgHrv = 60.0) }
        assertNull(IllnessWatch.evaluate(days))
    }

    @Test
    fun illness_clearBaselineReturnsNull() {
        // 31 stable days: recent == baseline, no anomalies.
        val days = (0 until 31).map {
            day("2026-01-%02d".format(it + 1), restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 14.0)
        }
        assertNull(IllnessWatch.evaluate(days))
    }

    /**
     * #2130: a signal may not accuse the recent window off a baseline the app would not otherwise use.
     *
     * 31 days of history, but HRV on only 2 of the baseline nights, so its fold is CALIBRATING and
     * `usable` is false. That is the field case verbatim (`hrvNValid=2, need nValid>=4`). Deliberately
     * below the seed rather than at it: 4 valid nights would be provisional by count and rejected only
     * for staleness, which would leave the test passing for a reason it does not name.
     *
     * RHR is dense and drops hard, so the RHR flag still fires; HRV must not, which leaves one flag and
     * no banner. The recent pair carries HRV, so this pins the BASELINE rather than merely "no data".
     */
    @Test
    fun illness_unusableHrvBaselineCannotRaiseAnHrvFlag() {
        val baseline = (0 until 31).map {
            day(
                "2026-01-%02d".format(it + 1),
                restingHr = 50,
                avgHrv = if (it < 2) 60.0 else null,
                skinTempDevC = 0.0,
                respRateBpm = 14.0,
            )
        }
        val recent = listOf(
            day("2026-02-01", restingHr = 58, avgHrv = 20.0, skinTempDevC = 0.0, respRateBpm = 14.0),
            day("2026-02-02", restingHr = 58, avgHrv = 20.0, skinTempDevC = 0.0, respRateBpm = 14.0),
        )
        assertNull(
            "one flag is not a banner, and a calibrating HRV fold is not a baseline",
            IllnessWatch.evaluate(baseline + recent),
        )
    }

    /** The same day shape, but with a fold that IS usable, still raises both flags. */
    @Test
    fun illness_usableHrvBaselineStillRaisesTheHrvFlag() {
        val baseline = (0 until 31).map {
            day("2026-01-%02d".format(it + 1), restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 14.0)
        }
        val recent = listOf(
            day("2026-02-01", restingHr = 58, avgHrv = 20.0, skinTempDevC = 0.0, respRateBpm = 14.0),
            day("2026-02-02", restingHr = 58, avgHrv = 20.0, skinTempDevC = 0.0, respRateBpm = 14.0),
        )
        val msg = IllnessWatch.evaluate(baseline + recent)
        assertNotNull(msg)
        assertTrue("the HRV flag is what the unusable case withholds", msg!!.contains("HRV"))
    }

    @Test
    fun illness_twoFlagsRaisesBanner() {
        // 31 calm days, then 2 strained recent days appended (33 total).
        // evaluate() uses takeLast(2) as recent and takeLast(31).dropLast(3) as baseline,
        // so the 2 strained days are "recent" and the calm days form the baseline.
        val baseline = (0 until 31).map {
            day("2026-01-%02d".format(it + 1), restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 14.0)
        }
        val recent = listOf(
            // RHR +8, HRV -25% (45/60), skin temp +0.8 -> three flags
            day("2026-02-01", restingHr = 58, avgHrv = 45.0, skinTempDevC = 0.8, respRateBpm = 14.0),
            day("2026-02-02", restingHr = 58, avgHrv = 45.0, skinTempDevC = 0.8, respRateBpm = 14.0),
        )
        val days = baseline + recent
        val msg = IllnessWatch.evaluate(days)
        assertNotNull(msg)
        assertTrue(msg!!.contains("resting HR"))
        assertTrue(msg.contains("HRV"))
        assertTrue(msg.contains("skin temp"))
    }

    @Test
    fun illness_singleFlagReturnsNull() {
        // Only resting HR elevated in the recent 2 days -> one flag -> null.
        val baseline = (0 until 31).map {
            day("2026-01-%02d".format(it + 1), restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 14.0)
        }
        val recent = listOf(
            day("2026-02-01", restingHr = 60, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 14.0),
            day("2026-02-02", restingHr = 60, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 14.0),
        )
        assertNull(IllnessWatch.evaluate(baseline + recent))
    }

    @Test
    fun illness_noisyRsaRespSingleOffNightDoesNotFire() {
        // Baseline resp ~15 bpm with realistic RSA night-to-night noise (alternating 14/16, sd>0),
        // stable RHR/HRV/skin-temp so resp is the ONLY candidate flag. Recent two days: one quiet
        // night at baseline and one +3 bpm RSA spike -> recent 2-day mean ~16.5, only ~+1.5 over
        // baseline ~15, below the +2.5 margin -> resp must NOT flag, so evaluate() returns null.
        val baseline = (0 until 31).map {
            day(
                "2026-01-%02d".format(it + 1),
                restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0,
                respRateBpm = if (it % 2 == 0) 14.0 else 16.0,
            )
        }
        val recent = listOf(
            day("2026-02-01", restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 15.0),
            day("2026-02-02", restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 18.0),
        )
        assertNull(IllnessWatch.evaluate(baseline + recent))
    }

    @Test
    fun illness_sustainedRespRiseStillFires() {
        // Same ~15 bpm plausible baseline, but BOTH recent nights are genuinely elevated (~18.5),
        // ~+3.5 over baseline (>= +2.5 margin) -> resp flags. Paired with an elevated RHR so two
        // flags fire and a banner is produced; assert it mentions respiration.
        val baseline = (0 until 31).map {
            day(
                "2026-01-%02d".format(it + 1),
                restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0,
                respRateBpm = if (it % 2 == 0) 14.0 else 16.0,
            )
        }
        val recent = listOf(
            day("2026-02-01", restingHr = 58, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 18.0),
            day("2026-02-02", restingHr = 58, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 19.0),
        )
        val msg = IllnessWatch.evaluate(baseline + recent)
        assertNotNull(msg)
        assertTrue(msg!!.contains("respiration"))
    }

    @Test
    fun illness_implausibleRespOutlierDoesNotFire() {
        // Degenerate RSA windows can yield implausible resp values. A baseline ~15 with recent
        // nights pinned at ~35 bpm (outside the 8-25 sanity band) must NOT fire the resp flag.
        val baseline = (0 until 31).map {
            day(
                "2026-01-%02d".format(it + 1),
                restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0,
                respRateBpm = if (it % 2 == 0) 14.0 else 16.0,
            )
        }
        val recent = listOf(
            day("2026-02-01", restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 35.0),
            day("2026-02-02", restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 35.0),
        )
        assertNull(IllnessWatch.evaluate(baseline + recent))
    }

    // --- sessionAvgHRV ectopic cleaning (#262/#235) -------------------------

    @Test
    fun sessionAvgHrv_rejectsEctopicSpikes() {
        // A 5-min window of steady ~900 ms beats (≈67 bpm) with a +600 ms ectopic
        // spike every 15th beat — the shape of PPG-derived 0x2A37 RR on a WHOOP 5/MG.
        // rMSSD is built from SUCCESSIVE differences, so the spikes would inflate the
        // session HRV if left in. cleanRR's Malik ectopic rejection drops them, so the
        // cleaned series is steady → HRV ≈ 0. Pre-fix (rangeFilter only) this path
        // returned ~200 ms; this guards against regression.
        val start = 1000L
        val end = start + 300
        val rr = (0 until 300).map { i ->
            RrInterval(deviceId = "d", ts = start + i, rrMs = if (i % 15 == 0) 1500 else 900)
        }
        val hrv = SleepStager.sessionAvgHRV(start, end, rr)
        assertNotNull(hrv)
        assertTrue("ectopic spikes must be rejected before rMSSD", hrv!! < 50.0)
    }
}
