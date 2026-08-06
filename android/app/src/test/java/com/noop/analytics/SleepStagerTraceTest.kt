package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SleepStagerTraceTest {
    private val dev = "test"
    private val refMidnight = 1_749_513_600L

    private fun still(start: Long, durS: Int) =
        (0 until durS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }
    private fun hr(start: Long, durS: Int, bpm: Int) =
        (0 until durS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    @Test fun runLineFormat() {
        val line = SleepStagerTrace.runLine(0, refMidnight, refMidnight + 5400,
            SleepStagerTrace.Verdict.KEPT, "minSleepMin", "spanMin=90 minSleepMin=60")
        assertEquals("gate run=0 spanS=5400 KEPT gate=minSleepMin spanMin=90 minSleepMin=60", line)
    }

    @Test fun flipLineFormat() {
        val line = SleepStagerTrace.flipLine(14, "wake", "sleep", "hrMult=1.05 bpm=49 baseline=52")
        assertEquals("epoch=14 flip wake->sleep threshold=hrMult=1.05 bpm=49 baseline=52", line)
    }

    @Test fun shortRunDropped() {
        val start = refMidnight + 2 * 3600
        val dur = 30 * 60
        val lines = ArrayList<String>()
        val sessions = SleepStager.detectSleep(
            hr = hr(start, dur, 50), gravity = still(start, dur), traceSink = { lines.add(it) })
        assertEquals(0, sessions.size)
        assertTrue(lines.any { it.contains("DROPPED gate=minSleepMin") })
    }

    /** The one-line detection summary must be emitted and reflect the pass: a single 30-min run is seen
     *  and dropped by minSleepMin, so kept=0 and droppedMinSleep=1. Twin of Swift. */
    @Test fun detectionSummaryLineEmitted() {
        val start = refMidnight + 2 * 3600
        val dur = 30 * 60
        val lines = ArrayList<String>()
        val sessions = SleepStager.detectSleep(
            hr = hr(start, dur, 50), gravity = still(start, dur), traceSink = { lines.add(it) })
        assertEquals(0, sessions.size)
        val summary = lines.firstOrNull { it.startsWith("sleep-detect summary:") }.orEmpty()
        assertTrue("expected a sleep-detect summary line, got: $lines", summary.startsWith("sleep-detect summary:"))
        // Guaranteed-true facts (no exact span/count pins — those depend on run-boundary mechanics):
        // nothing survived, so kept=0 and survivingSpanMin=0; a run WAS seen and dropped by minSleepMin.
        assertTrue(summary, summary.contains("kept=0"))
        assertTrue(summary, summary.contains("survivingSpanMin=0"))
        assertFalse(summary, summary.contains("droppedMinSleep=0"))
        assertFalse(summary, summary.contains("detectedSpanMin=0"))
    }

    @Test fun realNightKept() {
        val start = refMidnight + 2 * 3600
        val dur = 90 * 60
        val lines = ArrayList<String>()
        val sessions = SleepStager.detectSleep(
            hr = hr(start, dur, 50), gravity = still(start, dur), traceSink = { lines.add(it) })
        assertEquals(1, sessions.size)
        assertTrue(lines.any { it.contains("KEPT gate=accepted") })
        assertFalse(lines.any { it.contains("\u2014") })
    }

    @Test fun tracedAndUntracedReturnIdentical() {
        // The trace is side-effect-only: a traced and an untraced call return identical sessions.
        val start = refMidnight + 2 * 3600
        val dur = 90 * 60
        val untraced = SleepStager.detectSleep(hr = hr(start, dur, 50), gravity = still(start, dur))
        val traced = SleepStager.detectSleep(hr = hr(start, dur, 50), gravity = still(start, dur),
            traceSink = { })
        assertEquals(untraced, traced)
    }

    @Test fun denseNightHasNoSparseBridgeLine() {
        val start = refMidnight + 2 * 3600
        val dur = 90 * 60
        val lines = ArrayList<String>()
        SleepStager.detectSleep(hr = hr(start, dur, 50), gravity = still(start, dur),
            traceSink = { lines.add(it) })
        assertFalse(lines.any { it.contains("gate=sparseBridge") })
    }

    @Test fun restSubScoreLine() {
        val line = RestScorer.subScoreLine(
            tstSeconds = 8.0 * 3600, inBedSeconds = 8.0 * 3600 / 0.92, efficiency = 0.92,
            restorativeSeconds = 4.0 * 3600, needHours = 8.0, consistency = null,
            deepSeconds = 1.0 * 3600, groupFragments = 1, groupInBedSeconds = 8.0 * 3600 / 0.92)
        assertTrue(line.startsWith("rest "))
        assertTrue(line.contains("wDur=0.5"))
        assertTrue(line.contains("wEff=0.2"))
        assertTrue(line.contains("wRestor=0.2"))
        assertTrue(line.contains("wConsist=0.1"))
        assertTrue(line.contains("group=1"))
        assertFalse(line.contains("\u2014"))
    }
}
