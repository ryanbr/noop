package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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

    @Test
    fun logLineShape() {
        val r = RrEmissionStats.compute(listOf(Pair(10, 800), Pair(10, 820), Pair(11, 810)))
        val line = RrEmissionStats.logLine("historical", 3, 2, r)
        assertTrue(line, line.startsWith("rr emit path=historical offered=3 inserted=2 secs=2 "))
        assertTrue(line, line.contains("perSec[1/2/3/4+]=1/1/0/0"))
    }
}
