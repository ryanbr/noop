package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1937: a night whose sleep runs are ALL under `minSleepMin` produced no session at all, however much
 * sleep they added up to.
 *
 * The capture that found it: `sleepRuns=5 droppedMinSleep=5 kept=0 detectedSpanMin=298
 * survivingSpanMin=0 sparse=false`. Five hours of detected sleep, five runs averaging 59.6 minutes,
 * every one a minute short of the floor, and the night vanished. The rescue that exists for exactly
 * this was gated on the night being SPARSE, and the night was dense — on the reporting device gravity
 * coverage was 99.9%, so the bridge was declined precisely because the data was good.
 *
 * These pin the predicate that now also opens the bridge. Its safety property is the one that matters:
 * it can only turn nothing into something.
 */
class SleepFragmentedNightTest {

    private val minSleepS = 60L * 60      // the 60-minute session floor, in seconds

    private fun mins(vararg m: Long): List<Long> = m.map { it * 60 }

    /**
     * The reported shape: 298 minutes of detected sleep across five runs, none of them clearing the
     * floor. Note this night CANNOT be written in whole minutes: five runs each at most 59 min sum to
     * 295. Runs are second-granular, and 298/5 = 59.6 min, so each one falls 24 seconds short.
     */
    @Test
    fun theReportedFiveFragmentNightQualifies() {
        val runs = List(5) { 3576L }                       // 59.6 min each
        assertEquals(298L, runs.sum() / 60)                // the reported detectedSpanMin
        assertTrue(runs.all { it < minSleepS })            // and every one is dropped by the floor
        assertTrue(SleepStager.isFragmentedToNothing(runs, minSleepS))
    }

    /**
     * THE safety property. A night where any single run already clears the floor keeps at least one
     * session today, so the predicate must decline and leave the sparse rule to decide exactly as
     * before. Without this the change could alter a night that currently scores.
     */
    @Test
    fun aNightWithOneQualifyingRunIsNeverTouched() {
        // One 90-minute run plus fragments: today this scores, so the rescue must not engage.
        assertFalse(SleepStager.isFragmentedToNothing(mins(90, 20, 15), minSleepS))
        // Even when the qualifying run is exactly at the floor.
        assertFalse(SleepStager.isFragmentedToNothing(mins(60, 20, 15), minSleepS))
        // And when it is last rather than first.
        assertFalse(SleepStager.isFragmentedToNothing(mins(20, 15, 90), minSleepS))
    }

    /** A handful of brief stirs is not a night. The SUM has to clear the floor too. */
    @Test
    fun briefStirsDoNotBecomeANight() {
        assertFalse(SleepStager.isFragmentedToNothing(mins(5, 8, 12), minSleepS))
        // Just under the floor in total still declines.
        assertFalse(SleepStager.isFragmentedToNothing(mins(30, 29), minSleepS))
        // Exactly at it qualifies: the floor is what a night has to reach, not exceed.
        assertTrue(SleepStager.isFragmentedToNothing(mins(30, 30), minSleepS))
    }

    /** One fragment is not a fragmented night; there is nothing to bridge it to. */
    @Test
    fun aSingleShortRunIsNotAFragmentedNight() {
        assertFalse(SleepStager.isFragmentedToNothing(mins(59), minSleepS))
        assertFalse(SleepStager.isFragmentedToNothing(emptyList(), minSleepS))
    }

    /**
     * The predicate only ever opens the bridge. It cannot decide the outcome, because the bridge's own
     * rules still apply underneath — this test states the contract in the one place a future reader
     * would look for it, since the predicate's name suggests more authority than it has.
     */
    @Test
    fun thePredicateEnablesAnAttemptRatherThanGrantingIt() {
        val fragmented = mins(40, 40)
        assertTrue(SleepStager.isFragmentedToNothing(fragmented, minSleepS))
        // Two 40-minute runs separated by a gap far beyond the bridge's limit are still refused by the
        // bridge itself, which is where gap, intervening-active and HR-band checks live.
        val far = SleepStager.bridgeSparseSleepTraced(
            listOf(SleepStager.Period("sleep", 0, 40 * 60),
                   SleepStager.Period("sleep", 40 * 60 + 10 * 3600, 40 * 60 + 10 * 3600 + 40 * 60)),
            sparse = true, hr = emptyList(), baseline = null,
        )
        assertEquals("a gap of hours must not be bridged", 2, far.first.count { it.stage == "sleep" })
    }

    // ---- end-to-end: the reported night through detectSleep ----

    private val dev = "test"
    private val refMidnight = 1_749_513_600L                    // 2025-06-10 00:00:00 UTC
    private fun at(min: Int) = refMidnight + min * 60L

    /** Still gravity at 1/min: continuous, so the night reads DENSE, which is the point of #1937. */
    private fun still(fromMin: Int, toMin: Int) =
        (at(fromMin) until at(toMin) step 60).map {
            GravitySample(deviceId = dev, ts = it, x = 0.0, y = 0.0, z = 1.0)
        }

    /** Moving gravity at 1/min: orientation swings every sample, so this reads as an active run. */
    private fun moving(fromMin: Int, toMin: Int) =
        (at(fromMin) until at(toMin) step 60).mapIndexed { i, t ->
            if (i % 2 == 0) GravitySample(deviceId = dev, ts = t, x = 1.0, y = 0.0, z = 0.0)
            else GravitySample(deviceId = dev, ts = t, x = 0.0, y = 1.0, z = 0.0)
        }

    private fun hr1Hz(fromMin: Int, toMin: Int, bpm: Int) =
        (at(fromMin) until at(toMin)).map { HrSample(deviceId = dev, ts = it, bpm = bpm) }

    /**
     * The reported night end to end: five sleep runs of 59 minutes, each separated by a 20-minute
     * stir, gravity continuous throughout so the night is DENSE. Every run is under the 60-minute
     * floor, so before this change the night scored nothing at all.
     *
     * Five runs means the bridge has to chain FOUR consecutive absorptions, which is the part the pure
     * predicate tests cannot reach.
     *
     * The stir length is load-bearing at BOTH ends and a first attempt at 3 minutes made this test pass
     * for the wrong reason. `mergePeriods` absorbs any run under `mergeMin` (15) and rejoins the
     * same-stage neighbours, so short stirs never fragmented the night: it arrived as ONE 306-minute
     * run that always scored, and the rescue under test never ran. The stir must therefore be at least
     * mergeMin to survive the merge, and at most sparseBridgeActiveMaxInBandMin (60, since HR stays in
     * the sleep band) for the bridge to absorb it.
     */
    private fun fragmentedDenseNight(): Pair<List<HrSample>, List<GravitySample>> {
        var g = emptyList<GravitySample>()
        var t = 0
        repeat(5) { i ->
            g = g + still(t, t + 59)
            t += 59
            if (i < 4) { g = g + moving(t, t + 20); t += 20 }
        }
        return hr1Hz(0, t, 50) to g
    }

    @Test
    fun theFragmentedDenseNightIsRescuedEndToEnd() {
        val (hr, grav) = fragmentedDenseNight()
        assertFalse("the fixture must be DENSE, or the old sparse gate would already rescue it",
            SleepStager.isGravitySparse(grav, hr))

        val lines = ArrayList<String>()
        val sessions = SleepStager.detectSleep(hr = hr, gravity = grav, traceSink = { lines.add(it) })

        assertTrue("a night of five 59-minute runs must now produce a session, got none.\n" +
            lines.joinToString("\n"), sessions.isNotEmpty())
        val spanMin = sessions.sumOf { (it.end - it.start) / 60 }
        assertTrue("expected most of the 295 sleeping minutes, got $spanMin", spanMin >= 240)
        // Anti-vacuity: the session must exist BECAUSE the rescue fired. Without this the test passes
        // when the fixture is not actually fragmented, which is exactly what a 3-minute stir did.
        assertTrue("the session must come from the #1937 rescue, not from an unfragmented fixture.\n" +
            lines.joinToString("\n"),
            lines.any { it.contains("gate=sparseBridge ") && it.contains("fragmentedToNothing=true") })
    }

    /** The trace must name BOTH gates, so a dense rescue cannot contradict the summary line beside it. */
    @Test
    fun theTraceNamesBothGates() {
        val (hr, grav) = fragmentedDenseNight()
        val lines = ArrayList<String>()
        SleepStager.detectSleep(hr = hr, gravity = grav, traceSink = { lines.add(it) })
        val bridge = lines.firstOrNull { it.contains("gate=sparseBridge ") }
        assertTrue("expected a sparseBridge line, got:\n" + lines.joinToString("\n"), bridge != null)
        // The contiguous substring pins key ORDER and spacing, not just presence. Nothing in the tree
        // compares the two languages' trace output automatically, so a format change on one side would
        // otherwise diverge in silence; the Swift twin asserts this identical fragment.
        assertTrue("unexpected sparseBridge detail format: $bridge",
            bridge!!.contains("sparse=false fragmentedToNothing=true gapMin="))
    }
}
