package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The per-night baseline-fold trace. Twin of the Swift `BaselinesTraceTests` — the SAME fixtures and
 * the SAME expected strings, because a diagnostic whose two platforms word things differently cannot be
 * compared across a pair of reports.
 *
 * The contract that matters most is the first test: the traced state must BE the real fold's, so the
 * trace can never describe a baseline the scorer isn't using.
 */
class BaselinesTraceTest {

    private val hrv = Baselines.metricCfg["hrv"]!!

    /** The whole point: tracing must not change, or re-derive, the state. */
    @Test fun tracedStateIsTheRealFoldsState() {
        var traced: BaselineState? = null
        var real: BaselineState? = null
        val nights = listOf(60.0, 70.0, null, 999.0, 55.0, 62.0, 58.0, 61.0, 150.0, 59.0)
        for (v in nights) {
            traced = BaselinesTrace.updateTrace(traced, v, hrv, "hrv").state
            real = Baselines.update(real, v, hrv)
            assertEquals("baseline diverged after $v", real!!.baseline, traced!!.baseline, 0.0)
            assertEquals("spread diverged after $v", real.spread, traced.spread, 0.0)
            assertEquals("nValid diverged after $v", real.nValid, traced.nValid)
            assertEquals("status diverged after $v", real.status, traced.status)
        }
    }

    @Test fun seedNamesThatOneNightFixesTheCentre() {
        assertEquals(
            "baseline hrv night=seed value=60.0 spread starts at floor=5.0 " +
                "(this ONE night fixes the centre) -> mean=60.0 spread=5.0 nValid=1 status=calibrating",
            BaselinesTrace.updateTrace(null, 60.0, hrv, "hrv").lines[0],
        )
    }

    /** A first night with no usable value seeds the MIDPOINT and leaves nValid at 0 — not a skip. */
    @Test fun seedEmptyIsDistinctFromASkip() {
        assertEquals(
            "baseline hrv night=seed-empty no usable first value (bounds=5.0..250.0) " +
                "seeded at midpoint, nValid stays 0 -> mean=127.5 spread=5.0 nValid=0 status=calibrating",
            BaselinesTrace.updateTrace(null, null, hrv, "hrv").lines[0],
        )
    }

    @Test fun missingNightIsSkipAndHold() {
        val s = BaselinesTrace.updateTrace(null, 60.0, hrv, "hrv").state
        assertEquals(
            "baseline hrv night=missing skip-and-hold nightsSinceUpdate=1 " +
                "-> mean=60.0 spread=5.0 nValid=1 status=calibrating",
            BaselinesTrace.updateTrace(s, null, hrv, "hrv").lines[0],
        )
    }

    @Test fun implausibleNightNamesTheBounds() {
        val s = BaselinesTrace.updateTrace(null, 60.0, hrv, "hrv").state
        assertEquals(
            "baseline hrv night=implausible value=999.0 bounds=5.0..250.0 skip-and-hold " +
                "nightsSinceUpdate=1 -> mean=60.0 spread=5.0 nValid=1 status=calibrating",
            BaselinesTrace.updateTrace(s, 999.0, hrv, "hrv").lines[0],
        )
    }

    /** While young the fold uses the fast half-life and the inflated Winsor band; the line says so. */
    @Test fun foldedYoungReportsTheEarlyAdaptation() {
        val s = BaselinesTrace.updateTrace(null, 60.0, hrv, "hrv").state
        assertEquals(
            "baseline hrv night=folded value=70.0 young=yes effSpread=12.5 halfLifeB=3.0 " +
                "winsor=22.5..97.5 clamped=no spread 5.0->5.1 atFloor=no " +
                "-> mean=62.06 spread=5.1 nValid=2 status=calibrating",
            BaselinesTrace.updateTrace(s, 70.0, hrv, "hrv").lines[0],
        )
    }

    /** A hard outlier is "seen, NOT folded" — the case that otherwise leaves no trace at all. */
    @Test fun rejectedNightIsNamedWithItsThreshold() {
        val settled = BaselinesTrace.foldHistoryTrace(List(10) { 60.0 }, hrv, "hrv").state
        assertEquals(
            "baseline hrv night=rejected value=150.0 dev=90.0 > k=5.0*spread=5.0 (seen, NOT folded) " +
                "-> mean=60.0 spread=5.0 nValid=10 status=provisional",
            BaselinesTrace.updateTrace(settled, 150.0, hrv, "hrv").lines[0],
        )
    }

    @Test fun foldedSettledUsesTheNormalHalfLifeAndBand() {
        val settled = BaselinesTrace.foldHistoryTrace(List(10) { 60.0 }, hrv, "hrv").state
        assertEquals(
            "baseline hrv night=folded value=66.0 young=no effSpread=5.0 halfLifeB=14.0 " +
                "winsor=45.0..75.0 clamped=no spread 5.0->5.02 atFloor=no " +
                "-> mean=60.29 spread=5.02 nValid=11 status=provisional",
            BaselinesTrace.updateTrace(settled, 66.0, hrv, "hrv").lines[0],
        )
    }

    /**
     * The reason this file exists: a flat history leaves the spread ON its floor for as long as you
     * care to fold, and `atFloor=yes` is the only way a log ever says so. Every other diagnostic shows
     * a settled-looking spread=5.0 with nothing to distinguish it from a converged one.
     */
    @Test fun aFlatHistoryReportsSpreadPinnedOnTheFloor() {
        val out = BaselinesTrace.foldHistoryTrace(List(12) { 60.0 }, hrv, "hrv")
        assertEquals(5.0, out.state.spread, 0.0)
        val folded = out.lines.filter { it.contains("night=folded") }
        assertTrue("expected folded nights", folded.isNotEmpty())
        assertTrue("a flat history must report atFloor=yes", folded.all { it.contains("atFloor=yes") })
    }

    /** One line per night, in order, so a history reads as a trajectory. */
    @Test fun foldHistoryTraceEmitsOneLinePerNight() {
        val out = BaselinesTrace.foldHistoryTrace(listOf(60.0, null, 62.0, 999.0, 58.0), hrv, "hrv")
        assertEquals(5, out.lines.size)
        assertTrue(out.lines[0].contains("night=seed"))
        assertTrue(out.lines[1].contains("night=missing"))
        assertTrue(out.lines[2].contains("night=folded"))
        assertTrue(out.lines[3].contains("night=implausible"))
    }

    @Test fun emptyHistoryIsSafe() {
        val out = BaselinesTrace.foldHistoryTrace(emptyList(), hrv, "hrv")
        assertEquals(listOf("baseline hrv history=empty"), out.lines)
        assertEquals(0, out.state.nValid)
    }

    /** Project convention: no em-dashes leak into a log line. */
    @Test fun noEmDashesInAnyLine() {
        val out = BaselinesTrace.foldHistoryTrace(listOf(60.0, null, 999.0, 70.0, 150.0), hrv, "hrv")
        assertTrue(out.lines.isNotEmpty())
        assertFalse(out.lines.any { it.contains("—") })
    }

    /** The tail cap bounds the log without changing the state: the whole history is still folded. */
    @Test fun tailCapsTheLinesButNotTheFold() {
        val full = BaselinesTrace.foldHistoryTrace(List(30) { 60.0 + it }, hrv, "hrv")
        val capped = BaselinesTrace.foldHistoryTrace(List(30) { 60.0 + it }, hrv, "hrv", tail = 5)
        assertEquals("state must not depend on the cap", full.state.baseline, capped.state.baseline, 0.0)
        assertEquals(full.state.nValid, capped.state.nValid)
        assertEquals(6, capped.lines.size)   // 1 omission notice + 5 nights
        assertEquals("baseline hrv (earlier 25 night(s) omitted)", capped.lines[0])
        assertEquals(full.lines.takeLast(5), capped.lines.drop(1))
    }

    /** A tail bigger than the history leaves it untouched, with no misleading omission notice. */
    @Test fun tailLargerThanHistoryAddsNoNotice() {
        val out = BaselinesTrace.foldHistoryTrace(List(3) { 60.0 }, hrv, "hrv", tail = 14)
        assertEquals(3, out.lines.size)
        assertFalse(out.lines.any { it.contains("omitted") })
    }

    /**
     * The recalibration drop, named. This is #731's failure mode: the tap discards earlier nights and
     * restarts the count, and no log ever said so.
     */
    @Test fun recalibrationDropIsNamedAndMatchesTheRealFold() {
        val days = listOf("2026-08-01", "2026-08-02", "2026-08-03", "2026-08-04", "2026-08-05")
        val values = listOf<Double?>(60.0, 61.0, 62.0, 63.0, 64.0)
        // Epoch at 2026-08-04 UTC start-of-day: the first three nights are dropped.
        val epoch = java.time.LocalDate.parse("2026-08-04")
            .atStartOfDay(java.time.ZoneOffset.UTC).toEpochSecond().toDouble()
        val out = BaselinesTrace.foldHistoryTrace(values, days, hrv, "hrv", epoch)
        assertEquals(
            "baseline hrv recalibrated=2026-08-04 dropped=3 night(s) before it",
            out.lines[0],
        )
        // and the state is the REAL recalibration-aware fold's, not a re-derivation
        val real = Baselines.foldHistory(values, days, hrv, epoch)
        assertEquals(real.baseline, out.state.baseline, 0.0)
        assertEquals(real.spread, out.state.spread, 0.0)
        assertEquals(real.nValid, out.state.nValid)
    }

    /** No epoch set: identical to the plain fold, with no recalibration line invented. */
    @Test fun noRecalibrationEpochBehavesLikeThePlainFold() {
        val days = listOf("2026-08-01", "2026-08-02", "2026-08-03")
        val values = listOf<Double?>(60.0, 61.0, 62.0)
        val out = BaselinesTrace.foldHistoryTrace(values, days, hrv, "hrv", 0.0)
        val plain = BaselinesTrace.foldHistoryTrace(values, hrv, "hrv")
        assertEquals(plain.lines, out.lines)
        assertEquals(plain.state.baseline, out.state.baseline, 0.0)
    }

    /**
     * dayKeys SHORTER than values: the real fold only tests the epoch for indices it has a key for, and
     * keeps the rest. The trace filters on the same condition, so the states must agree — this is the
     * case where a filter-then-fold shortcut could silently diverge from a fold-with-skips.
     */
    @Test fun shortDayKeysKeepTheUndatedNightsExactlyLikeTheRealFold() {
        val values = listOf<Double?>(60.0, 61.0, 62.0, 63.0, 64.0)
        val days = listOf("2026-08-01", "2026-08-02")   // only two keys for five nights
        val epoch = java.time.LocalDate.parse("2026-08-02")
            .atStartOfDay(java.time.ZoneOffset.UTC).toEpochSecond().toDouble()
        val out = BaselinesTrace.foldHistoryTrace(values, days, hrv, "hrv", epoch)
        val real = Baselines.foldHistory(values, days, hrv, epoch)
        assertEquals(real.baseline, out.state.baseline, 0.0)
        assertEquals(real.spread, out.state.spread, 0.0)
        assertEquals(real.nValid, out.state.nValid)
        assertTrue(out.lines[0].contains("dropped=1"))   // only 2026-08-01 precedes the epoch
    }

    /** tail = 0 keeps the notice and nothing else, rather than emitting an empty list. */
    @Test fun tailOfZeroKeepsOnlyTheOmissionNotice() {
        val out = BaselinesTrace.foldHistoryTrace(List(4) { 60.0 }, hrv, "hrv", tail = 0)
        assertEquals(listOf("baseline hrv (earlier 4 night(s) omitted)"), out.lines)
        assertEquals(4, out.state.nValid)
    }

    /** A negative tail is ignored rather than trimming anything. */
    @Test fun negativeTailIsIgnored() {
        val out = BaselinesTrace.foldHistoryTrace(List(4) { 60.0 }, hrv, "hrv", tail = -1)
        assertEquals(4, out.lines.size)
        assertFalse(out.lines.any { it.contains("omitted") })
    }

    /** The recalibration line must SURVIVE the tail cap: it is prepended after trimming, not trimmed. */
    @Test fun recalibrationLineSurvivesATightTail() {
        val values = List<Double?>(20) { 60.0 + it }
        val days = List(20) { "2026-08-%02d".format(it + 1) }
        val epoch = java.time.LocalDate.parse("2026-08-05")
            .atStartOfDay(java.time.ZoneOffset.UTC).toEpochSecond().toDouble()
        val out = BaselinesTrace.foldHistoryTrace(values, days, hrv, "hrv", epoch, tail = 3)
        assertTrue("recalibration line must not be trimmed", out.lines[0].contains("recalibrated="))
        assertTrue(out.lines[1].contains("omitted"))
        assertEquals(5, out.lines.size)   // recalibration + notice + 3 nights
    }
}
