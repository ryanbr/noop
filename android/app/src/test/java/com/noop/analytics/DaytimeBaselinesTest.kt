package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Kotlin twin of StrandAnalytics DaytimeBaselinesTests (PR #463): coverage for the CALLER-side
 * daytime-baseline fold (DaytimeBaselines) that feeds DaytimeStress.analyze(mode = BaselineRelative)
 * — the per-day aggregate definition, the trailing-history fold, the graceful-degradation
 * scoringMode gate, and the fold→score round trip. Pure-function tests; no DB.
 */
class DaytimeBaselinesTest {

    // MARK: - Fixtures (multi-day: day `d` is offset by d·86 400 s; local hour-of-day is preserved)

    /** One local day of HR: every hour in [hours] filled with [n] 1 Hz samples at a per-hour bpm. */
    private fun dayHr(dayIndex: Int, hours: List<Int>, bpms: List<Int>,
                      n: Int = DaytimeStress.minHourHrSamples): List<HrSample> {
        val dayBase = dayIndex.toLong() * 86_400L
        val out = ArrayList<HrSample>()
        for ((h, bpm) in hours.zip(bpms)) {
            val base = dayBase + h.toLong() * 3_600L
            for (i in 0 until n) out.add(HrSample(deviceId = "t", ts = base + i, bpm = bpm))
        }
        return out
    }

    /** One local day flat at a single bpm across waking hours 8…17 (ten scored hours). */
    private fun flatDayHr(dayIndex: Int, bpm: Int): List<HrSample> =
        dayHr(dayIndex, (8..17).toList(), List(10) { bpm })

    /** R-R for one local hour with a controllable beat-to-beat jitter (drives RMSSD). */
    private fun hourRr(dayIndex: Int, hour: Int, rrMs: Int, jitter: Int, n: Int = 120): List<RrInterval> {
        val base = dayIndex.toLong() * 86_400L + hour.toLong() * 3_600L
        return (0 until n).map {
            RrInterval(deviceId = "t", ts = base + it * 30L, rrMs = rrMs + if (it % 2 == 0) jitter else -jitter)
        }
    }

    private fun flatDayRr(dayIndex: Int, rrMs: Int, jitter: Int): List<RrInterval> =
        (8..17).flatMap { hourRr(dayIndex, it, rrMs, jitter) }

    // MARK: - Per-day aggregate

    @Test
    fun dayHRAggregateIsTheTenthPercentileOfWakingHourMeanHRs() {
        // Ten waking hours (08…17) with a spread of constant per-hour HRs; each hour's MEAN HR is
        // just its bpm. P10 of [60,62,64,66,68,70,72,74,76,78] via the shared linear-interp quantile
        // is 60 + 0.9·(62−60) = 61.8 — the calm floor, well below the day's median.
        val bpms = listOf(60, 62, 64, 66, 68, 70, 72, 74, 76, 78)
        val hr = dayHr(0, (8..17).toList(), bpms)
        val agg = DaytimeBaselines.dayDaytimeAggregate(hr, emptyList(), 0L)
        assertNotNull(agg.hr)
        assertEquals(61.8, agg.hr!!, 1e-6)
        assertNull("no R-R → no daytime RMSSD aggregate", agg.rmssd)
    }

    @Test
    fun dayHRAggregateAppliesTheSameMinSamplesGateAsTheScorer() {
        // An under-gate sparse hour at a very low bpm must NOT drag the P10 floor down — the scorer
        // would never score it, so the aggregate must not reference it either.
        val dense = dayHr(0, (8..17).toList(), listOf(60, 62, 64, 66, 68, 70, 72, 74, 76, 78))
        val sparse = dayHr(0, listOf(7), listOf(40), n = DaytimeStress.minHourHrSamples - 1)
        val withSparse = DaytimeBaselines.dayDaytimeAggregate(dense + sparse, emptyList(), 0L)
        val denseOnly = DaytimeBaselines.dayDaytimeAggregate(dense, emptyList(), 0L)
        assertEquals("a below-gate hour leaked into the daytime-HR floor",
            denseOnly.hr!!, withSparse.hr!!, 1e-9)
    }

    @Test
    fun dayHRAggregateExcludesNonWakingHours() {
        // A very low 03:00 hour (outside 06:00–22:00) must not become the calm floor.
        val waking = dayHr(0, (8..17).toList(), listOf(60, 62, 64, 66, 68, 70, 72, 74, 76, 78))
        val night = dayHr(0, listOf(3), listOf(45))
        val withNight = DaytimeBaselines.dayDaytimeAggregate(waking + night, emptyList(), 0L)
        assertEquals("a non-waking hour leaked into the daytime-HR floor", 61.8, withNight.hr!!, 1e-6)
    }

    @Test
    fun dayRMSSDAggregateIsPresentWithRRAndTracksVariability() {
        // A relaxed day (high jitter → high RMSSD) vs a suppressed day (low jitter → low RMSSD):
        // both produce a non-null median RMSSD aggregate, and the relaxed day's is clearly higher.
        val hr = flatDayHr(0, 65)
        val relaxed = DaytimeBaselines.dayDaytimeAggregate(hr, flatDayRr(0, 900, 45), 0L)
        val suppressed = DaytimeBaselines.dayDaytimeAggregate(hr, flatDayRr(0, 900, 5), 0L)
        assertNotNull(relaxed.rmssd)
        assertNotNull(suppressed.rmssd)
        assertTrue("the higher-variability day should carry a higher median daytime RMSSD",
            relaxed.rmssd!! > suppressed.rmssd!!)
    }

    // MARK: - Fold trailing history

    @Test
    fun foldConvergesHRBaselineToThePersonalDaytimeFloor() {
        // Twelve identical days whose P10 daytime HR is exactly 65 → the EWMA center converges to 65
        // and the baseline is usable (12 ≥ minNightsSeed). No R-R anywhere → RMSSD baseline is null.
        val days = (0 until 12).map { DaytimeBaselines.DaytimeDayStreams(flatDayHr(it, 65), emptyList(), 0L) }
        val b = DaytimeBaselines.foldDaytimeBaselines(days)
        assertEquals(65.0, b.hr.baseline, 1e-6)
        assertTrue(b.hr.usable)
        assertNull("no daytime R-R history → HR-only baseline", b.rmssd)
    }

    @Test
    fun foldReturnsRMSSDBaselineOnlyWhenEnoughDaytimeRRDays() {
        // Two days of R-R is below minNightsSeed → RMSSD baseline withheld (null → HR-only). Eight
        // days clears the seed → a usable RMSSD baseline is returned.
        val twoDays = (0 until 2).map {
            DaytimeBaselines.DaytimeDayStreams(flatDayHr(it, 65), flatDayRr(it, 900, 40), 0L)
        }
        assertNull("an untrustworthy 2-day RMSSD baseline must be withheld",
            DaytimeBaselines.foldDaytimeBaselines(twoDays).rmssd)

        val eightDays = (0 until 8).map {
            DaytimeBaselines.DaytimeDayStreams(flatDayHr(it, 65), flatDayRr(it, 900, 40), 0L)
        }
        val rmssd = DaytimeBaselines.foldDaytimeBaselines(eightDays).rmssd
        assertNotNull("eight days of daytime R-R should yield a usable RMSSD baseline", rmssd)
        assertTrue(rmssd!!.usable)
    }

    // MARK: - scoringMode graceful degradation

    @Test
    fun scoringModeFallsBackToDayRelativeOnColdStartAndSparseHistory() {
        // No history → day-relative (cold start unchanged).
        assertTrue("empty history must fall back to DayRelative",
            DaytimeBaselines.scoringMode(emptyList()) is DaytimeStress.ScoringMode.DayRelative)
        // Three days is below minNightsSeed → still day-relative.
        val threeDays = (0 until 3).map { DaytimeBaselines.DaytimeDayStreams(flatDayHr(it, 65), emptyList(), 0L) }
        assertTrue("sub-seed history must fall back to DayRelative",
            DaytimeBaselines.scoringMode(threeDays) is DaytimeStress.ScoringMode.DayRelative)
    }

    @Test
    fun scoringModeUsesBaselineRelativeOnceHistoryIsUsable() {
        // Six days of real daytime HR clears the seed → the Oura-style baseline-relative mode,
        // carrying the folded HR baseline (~65) and a null RMSSD baseline (no R-R history here).
        val days = (0 until 6).map { DaytimeBaselines.DaytimeDayStreams(flatDayHr(it, 65), emptyList(), 0L) }
        val mode = DaytimeBaselines.scoringMode(days)
        if (mode !is DaytimeStress.ScoringMode.BaselineRelative) {
            fail("usable history must select BaselineRelative"); return
        }
        assertEquals(65.0, mode.hr.baseline, 1e-6)
        assertNull(mode.rmssd)
    }

    // MARK: - Fold → score round trip (the whole point)

    @Test
    fun foldedBaselineScoresElevationAgainstThePersonalFloorNotTheDaysOwnHours() {
        // Personal floor folded from history = 65 bpm. TODAY is elevated ALL day (every waking hour
        // 80 = 65 + the validated 15 bpm margin). A DAY-relative read would anchor on the day's OWN
        // hours and miss an all-day-high day; the baseline-relative read scores it against the
        // personal 65 floor, so every hour lands at/above the HIGH band and logs high-stress minutes.
        val history = (0 until 20).map { DaytimeBaselines.DaytimeDayStreams(flatDayHr(it, 65), emptyList(), 0L) }
        val mode = DaytimeBaselines.scoringMode(history)
        if (mode !is DaytimeStress.ScoringMode.BaselineRelative) { fail("expected baseline-relative"); return }

        val today = flatDayHr(0, 80)
        val r = DaytimeStress.analyze(today, emptyList(), tzOffsetSeconds = 0L, mode = mode)
        assertFalse(r.scored.isEmpty())
        assertTrue("no RMSSD baseline → HR-only, honestly flagged", r.hrOnlyFallback)
        assertTrue("an all-day-elevated day must log high-stress time", r.highStressMinutes > 0)
        for (p in r.scored) {
            assertTrue("80 bpm is the personal floor + the validated 15 bpm margin → the HIGH band",
                p.level!! >= DaytimeStress.highBandFloor - 0.05)
        }
    }

    @Test
    fun foldedBaselineCalmDayAtThePersonalFloorReadsNeutralNotHigh() {
        // TODAY sits exactly at the personal 65 floor all day → each hour reads ~1.5 (neutral),
        // never high. Guards the calm end of the scale end-to-end through the fold.
        val history = (0 until 20).map { DaytimeBaselines.DaytimeDayStreams(flatDayHr(it, 65), emptyList(), 0L) }
        val mode = DaytimeBaselines.scoringMode(history)
        val r = DaytimeStress.analyze(flatDayHr(0, 65), emptyList(), tzOffsetSeconds = 0L, mode = mode)
        assertEquals(0, r.highStressMinutes)
        for (p in r.scored) assertEquals(1.5, p.level!!, 0.05)
    }

    @Test
    fun medianRMSSDBaselineKeepsANormalHourNeutralNoStacking() {
        // The anti-stacking guarantee behind anchoring the RMSSD aggregate at the MEDIAN (not a calm
        // ceiling): with BOTH a HR baseline (65) and an RMSSD baseline folded from history, a TODAY
        // that sits at the HR floor AND at its typical daytime HRV must stay out of the HIGH band. A
        // ceiling anchor would make this ordinary hour read ~1–2σ "below baseline" and stack a false
        // stress term.
        val history = (0 until 20).map {
            DaytimeBaselines.DaytimeDayStreams(flatDayHr(it, 65), flatDayRr(it, 900, 40), 0L)
        }
        // Build the RMSSD-active mode DIRECTLY from the fold, bypassing the scoringMode gate that
        // holds RMSSD out of LIVE scoring until validated (DaytimeStress.daytimeRMSSDScoringEnabled
        // is false). This test pins the anti-stacking guarantee of the RMSSD-active scoring path
        // itself, so it must exercise that path regardless of the production gate. scoringMode's own
        // gating is covered by scoringModeHoldsRMSSDOutOfLiveScoreWhileGated below.
        val baselines = DaytimeBaselines.foldDaytimeBaselines(history)
        assertNotNull("20 days of daytime R-R should yield a usable RMSSD baseline", baselines.rmssd)
        val mode = DaytimeStress.ScoringMode.BaselineRelative(baselines.hr, baselines.rmssd)

        // Today: HR at the floor, HRV at the SAME typical variability as history.
        val today = flatDayHr(0, 65)
        val todayRr = flatDayRr(0, 900, 40)
        val r = DaytimeStress.analyze(today, todayRr, tzOffsetSeconds = 0L, mode = mode)
        assertFalse("an RMSSD baseline was supplied", r.hrOnlyFallback)
        assertEquals("a typical HR+HRV day must not read as high stress", 0, r.highStressMinutes)
        for (p in r.scored) {
            assertTrue("a normal hour with an RMSSD baseline must not stack into the HIGH band",
                p.level!! < DaytimeStress.highBandFloor)
        }
    }

    @Test
    fun scoringModeHoldsRMSSDOutOfLiveScoreWhileGated() {
        // The live-scoring gate: even with a full daytime-RR history that folds a USABLE RMSSD
        // baseline, scoringMode (the production entry point) keeps RMSSD OUT of the mode while
        // DaytimeStress.daytimeRMSSDScoringEnabled is false — so production scores HR-only, the
        // validated r≈0.6 channel. The fold still produces the usable baseline (the machinery is
        // live + tested); only its arrival at the score is gated. Flip the flag → this expectation
        // inverts, which is the intended tripwire for when RMSSD is validated on.
        val history = (0 until 20).map {
            DaytimeBaselines.DaytimeDayStreams(flatDayHr(it, 65), flatDayRr(it, 900, 40), 0L)
        }
        assertNotNull("precondition: the history must fold a usable RMSSD baseline",
            DaytimeBaselines.foldDaytimeBaselines(history).rmssd)
        val mode = DaytimeBaselines.scoringMode(history)
        if (mode !is DaytimeStress.ScoringMode.BaselineRelative) {
            fail("usable HR history must still select BaselineRelative"); return
        }
        assertTrue("HR baseline still drives the mode", mode.hr.usable)
        if (DaytimeStress.daytimeRMSSDScoringEnabled) {
            assertNotNull("flag on: the usable RMSSD baseline should reach live scoring", mode.rmssd)
        } else {
            assertNull("flag off: RMSSD is held out of the live score despite a usable baseline", mode.rmssd)
        }
    }
}
