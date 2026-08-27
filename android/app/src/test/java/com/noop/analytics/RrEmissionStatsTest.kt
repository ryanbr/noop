package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Kotlin twin of `RrEmissionStatsTests.swift` — same vectors, same expected numbers, so the two
 * platforms' pre-storage census cannot drift.
 *
 * `ratio` is the only sound discriminator here, and deliberately so: a cross-second repeat counter was
 * written first and deleted, because on a resting heart consecutive intervals are near-identical, so it
 * reported 9 "repeats" out of 10 honest beats. Physics bounds the ratio; resemblance bounds nothing.
 */
class RrEmissionStatsTest {

    @Test
    fun cleanEndToEndStreamRatioIsAboutOne() {
        val rr = mutableListOf<Pair<Int, Int>>()
        var tMs = 0
        while (tMs < 60_000) {                      // one minute of beats
            tMs += 860
            rr.add(Pair(1_000 + tMs / 1_000, 860))
        }
        val r = RrEmissionStats.compute(rr)
        assertEquals(70, r.intervals)               // ceil(60_000 / 860): the last beat ends just past the minute
        assertEquals(1.0, r.ratio, 0.05)
        assertEquals("a 60 bpm-ish heart never fills 3+ endings in one second",
            0, r.perSecond[2] + r.perSecond[3])
    }

    @Test
    fun doubledEmissionShowsAsRatioAboveOne() {
        val rr = mutableListOf<Pair<Int, Int>>()
        var tMs = 0
        while (tMs < 60_000) {
            tMs += 860
            val ts = 1_000 + tMs / 1_000
            rr.add(Pair(ts, 860))
            rr.add(Pair(ts, 860))                   // the same beat again
        }
        val r = RrEmissionStats.compute(rr)
        assertEquals(2.0, r.ratio, 0.1)
        assertTrue(r.perSecond[1] + r.perSecond[2] + r.perSecond[3] > 0)
    }

    @Test
    fun sameSecondChannelTwinsInflateTheRatio() {
        val rr = mutableListOf<Pair<Int, Int>>()
        for (i in 0 until 30) {
            rr.add(Pair(1_000 + i, 860))
            rr.add(Pair(1_000 + i, 894))            // same beat, other channel (+34 ms)
        }
        val r = RrEmissionStats.compute(rr)
        assertEquals(listOf(0, 30, 0, 0), r.perSecond)
        assertTrue(r.ratio > 1.7)
    }

    @Test
    fun degenerateBatches() {
        val empty = RrEmissionStats.compute(emptyList())
        assertEquals(0, empty.intervals)
        assertEquals(0.0, empty.ratio, 1e-9)
        assertEquals(listOf(0, 0, 0, 0), empty.perSecond)

        val one = RrEmissionStats.compute(listOf(Pair(5, 900)))
        assertEquals(1, one.spanSec)
        assertEquals(0.9, one.ratio, 1e-9)
    }

    @Test
    fun fourOrMoreBucketsTogether() {
        val rr = (0 until 5).map { Pair(1_000, 200 + it) }
        assertEquals(listOf(0, 0, 0, 1), RrEmissionStats.compute(rr).perSecond)
    }

    /**
     * #1451: a strap banking one record every 5 s is HEALTHY, but its reporting-second ratio reads ~5.
     * modalGap states the cadence so that ratio is read against the right baseline instead of against 1.0,
     * and fill shows each record's beat-time fits the slot it covers. Twin of Swift
     * `testModalGapReportsRecordCadenceAndFillFitsOnAHealthyMultiSecondStrap`.
     */
    @Test
    fun modalGapReportsRecordCadenceAndFillFitsOnAHealthyMultiSecondStrap() {
        // Six records, 5 s apart, each carrying 5 s of beat-time in 6 intervals (~833 ms each).
        val rr = mutableListOf<Pair<Int, Int>>()
        for (rec in 0 until 6) {
            repeat(6) { rr.add(rec * 5 to 833) }
        }
        val r = RrEmissionStats.compute(rr)
        assertEquals(5, r.modalGapSec)                 // cadence discovered, not assumed
        assertEquals(listOf(5, 0, 0, 0), r.fill)       // every bounded record fits its own slot
        val line = RrEmissionStats.logLine("historical", rr.size, rr.size, r)
        assertTrue(line, line.contains("modalGap=5s"))
        assertTrue(line, line.contains("fill[<=1/<=1.5/<=2/>2]=5/0/0/0"))
    }

    /**
     * #1451: the measurement a timeline fix needs. Records 1 s apart each carrying ~1.7 s of beat-time
     * overflow the interval they cover, so no scheme that places beats inside a record's own slot can be
     * correct. Twin of Swift `testFillCatchesRecordsCarryingMoreBeatTimeThanTheirSlot`.
     */
    @Test
    fun fillCatchesRecordsCarryingMoreBeatTimeThanTheirSlot() {
        val rr = mutableListOf<Pair<Int, Int>>()
        for (t in 0 until 5) {
            rr.add(t to 850)
            rr.add(t to 850)   // two full beats stamped on one 1 s record = 1.7x fill
        }
        val r = RrEmissionStats.compute(rr)
        assertEquals(1, r.modalGapSec)
        assertEquals(listOf(0, 0, 4, 0), r.fill)       // 1.7 lands in the <=2.0 bucket, four bounded records
        // The two measures are coupled, and that is the point: if every record fitted its slot the totals
        // could not exceed the span either. `ratio` says the session over-counts; `fill` says WHICH records.
        assertTrue("ratio=${r.ratio}", r.ratio > 1.0)
        assertTrue(RrEmissionStats.logLine("historical", 10, 10, r).contains("fill[<=1/<=1.5/<=2/>2]=0/0/4/0"))
    }

    @Test
    fun logLineShape() {
        val r = RrEmissionStats.compute(listOf(Pair(10, 800), Pair(10, 820), Pair(11, 810)))
        val line = RrEmissionStats.logLine("historical", 3, 2, r)
        assertTrue(line, line.startsWith("rr emit path=historical offered=3 inserted=2 secs=2 "))
        assertTrue(line, line.contains("perSec[1/2/3/4+]=1/1/0/0"))

        // A LIVE path censuses before the insert and cannot know what the conflict key kept, so it
        // passes null and the line must say "n/a". Echoing `offered` there would read as "the primary
        // key absorbed nothing" — a claim neither live path is in a position to make.
        val live = RrEmissionStats.logLine("live-standard", 3, null, r)
        assertTrue(live, live.startsWith("rr emit path=live-standard offered=3 inserted=n/a secs=2 "))
    }

    /**
     * A GAP must not read as healthy emission. Two doubled seconds an hour apart carry a 2.0 emission
     * defect, but the wall span between them dilutes `ratio` to almost nothing — so `ratio` alone would
     * report the OPPOSITE of the truth on exactly the session this instrumentation exists to judge.
     * `ratioRep` divides by the seconds that reported and holds at ~1.6. Twin of the Swift vector.
     */
    @Test
    fun gapDilutesSpanRatioButNotReportingRatio() {
        val rr = listOf(Pair(0, 800), Pair(0, 800), Pair(3_600, 800), Pair(3_600, 800))
        val r = RrEmissionStats.compute(rr)
        assertEquals(2, r.secondsWithRr)
        assertEquals(3_601, r.spanSec)
        assertTrue("span ratio is diluted by the gap, as documented", r.ratio < 0.01)
        val line = RrEmissionStats.logLine("historical", 4, 4, r)
        assertTrue(line, line.contains("ratio=0.00 ratioRep=1.60"))
    }

    /**
     * The LIVE census rate-limit. Twin of Swift `testShouldEmitLiveCensus` — same table, same answers,
     * oracle-checked against a standalone Swift build of the helper.
     *
     * The `lastEmit=0` rows are the ones that matter. The sentinel is checked explicitly, not left to
     * the gap arithmetic: with a real unix `nowSec` (~1.8e9) the subtraction clears any gap by accident
     * of magnitude, so the "first flush always reports" contract held in production while being false
     * for small timestamps — which is exactly what a unit test uses.
     */
    @Test fun shouldEmitLiveCensusRateLimits() {
        // never emitted -> always report, whatever the clock reads
        assertTrue(RrEmissionStats.shouldEmitLiveCensus(0, 0))
        assertTrue(RrEmissionStats.shouldEmitLiveCensus(0, 1))
        assertTrue(RrEmissionStats.shouldEmitLiveCensus(0, 1_700_000_000))
        // inside the window -> stay quiet
        assertFalse(RrEmissionStats.shouldEmitLiveCensus(1_700_000_000, 1_700_000_000))
        assertFalse(RrEmissionStats.shouldEmitLiveCensus(1_700_000_000, 1_700_000_899))
        // at and past the window -> report
        assertTrue(RrEmissionStats.shouldEmitLiveCensus(1_700_000_000, 1_700_000_900))
        assertTrue(RrEmissionStats.shouldEmitLiveCensus(1_700_000_000, 1_700_000_901))
        // clock moved BACKWARDS -> report rather than wedge the instrument shut until time catches up
        assertTrue(RrEmissionStats.shouldEmitLiveCensus(1_700_000_900, 1_700_000_000))
    }
}
