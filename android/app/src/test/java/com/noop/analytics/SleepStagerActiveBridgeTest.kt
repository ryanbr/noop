package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1657: the sparse-gravity bridge could only ever join sleep runs already adjacent in its own output,
 * so ANY active run between two sleep runs blocked the merge permanently. A field trace found it merging
 * nothing on 14 of 14 sparse nights for exactly that reason — and since a bathroom trip is definitionally
 * an active run, the rescue built for fragmentation was unavailable in the case that needs it most.
 *
 * The pieces then died at the 60-minute session floor, which is how a 6h40m night scored 150 minutes.
 */
class SleepStagerActiveBridgeTest {

    private fun sleep(start: Long, end: Long) = SleepStager.Period("sleep", start, end)
    private fun active(start: Long, end: Long) = SleepStager.Period("active", start, end)

    /** Flat HR well under the band, so the HR gate is never the thing under test. */
    private fun calmHr(from: Long, to: Long, bpm: Int = 50): List<HrSample> =
        (from..to step 60).map { HrSample(deviceId = "dev", ts = it, bpm = bpm) }

    private val baseline = 60.0

    /**
     * THE reported shape: asleep, a short trip, asleep again. Each piece is under the 60-minute session
     * floor on its own; together they are a night.
     */
    @Test
    fun `a short active interruption between two sleep runs is absorbed`() {
        val periods = listOf(sleep(0, 3000), active(3000, 3900), sleep(3900, 9000))
        val out = SleepStager.bridgeSparseSleep(periods, sparse = true, hr = calmHr(0, 9000), baseline = baseline)
        assertEquals(1, out.size)
        assertEquals("sleep", out[0].stage)
        assertEquals(0L, out[0].start)
        assertEquals(9000L, out[0].end)
    }

    /**
     * The guard that keeps this honest. A long active run is a real break in the night, not a stir, and
     * absorbing it would score wakefulness as sleep — wrong in a new direction and harder to notice than
     * the truncation being fixed.
     */
    @Test
    fun `an active run longer than the bound is left alone`() {
        val tooLong = (SleepStager.sparseBridgeActiveMaxMin * 60L) + 60L
        val periods = listOf(sleep(0, 3000), active(3000, 3000 + tooLong), sleep(3000 + tooLong, 9000))
        val out = SleepStager.bridgeSparseSleep(periods, sparse = true, hr = calmHr(0, 9000), baseline = baseline)
        assertEquals(3, out.size)
    }

    /**
     * HR is the real gate, not the duration bound. A wearer who is genuinely up keeps HR elevated for the
     * whole interruption, and that must still block the merge even when it is short.
     */
    @Test
    fun `a short interruption with elevated HR is not absorbed`() {
        val periods = listOf(sleep(0, 3000), active(3000, 3900), sleep(3900, 9000))
        val hot = calmHr(0, 3000) + calmHr(3001, 3900, bpm = 110) + calmHr(3901, 9000)
        val out = SleepStager.bridgeSparseSleep(periods, sparse = true, hr = hot, baseline = baseline)
        assertEquals(3, out.size)
    }

    /**
     * Two consecutive active runs are a night with structure in it, not one interruption. Only a single
     * intervening run is absorbed, or the bridge would walk across an arbitrarily fragmented evening.
     */
    @Test
    fun `two consecutive active runs are not absorbed`() {
        val periods = listOf(
            sleep(0, 3000), active(3000, 3300), active(3300, 3900), sleep(3900, 9000),
        )
        val out = SleepStager.bridgeSparseSleep(periods, sparse = true, hr = calmHr(0, 9000), baseline = baseline)
        assertEquals(4, out.size)
    }

    /** A dense 4.0 night must be byte-identical: the bridge is sparse-only and always has been. */
    @Test
    fun `a dense night is untouched`() {
        val periods = listOf(sleep(0, 3000), active(3000, 3900), sleep(3900, 9000))
        val out = SleepStager.bridgeSparseSleep(periods, sparse = false, hr = calmHr(0, 9000), baseline = baseline)
        assertEquals(periods, out)
    }

    /** The pre-existing behaviour — a bare gap between two sleep runs — still merges. */
    @Test
    fun `the original adjacent-pair merge still works`() {
        val periods = listOf(sleep(0, 3000), sleep(3600, 9000))
        val out = SleepStager.bridgeSparseSleep(periods, sparse = true, hr = calmHr(0, 9000), baseline = baseline)
        assertEquals(1, out.size)
        assertEquals(9000L, out[0].end)
    }

    /**
     * The trace has to say WHY, and the blocking length is the number a reader needs. The old trace could
     * only report runsBefore == runsAfter, which says the bridge did nothing and not what stopped it.
     */
    @Test
    fun `a blocked pair reports the bound that blocked it, with the active length`() {
        val tooLong = (SleepStager.sparseBridgeActiveMaxMin * 60L) + 60L
        val periods = listOf(sleep(0, 3000), active(3000, 3000 + tooLong), sleep(3000 + tooLong, 9000))
        val (_, attempts) = SleepStager.bridgeSparseSleepTraced(
            periods, sparse = true, hr = calmHr(0, 9000), baseline = baseline,
        )
        assertEquals(1, attempts.size)
        assertEquals("activeTooLong", attempts[0].reason)
        assertFalse(attempts[0].bridged)
        assertEquals(SleepStager.sparseBridgeActiveMaxMin + 1L, attempts[0].activeMin)
    }

    /**
     * The tracer and the merge are ONE pass. Swift kept a shadow copy of the loop purely to trace it,
     * which has to be edited in step with the real one — a trace that quietly disagrees with the
     * behaviour it describes is worse than no trace at all.
     */
    @Test
    fun `the traced pass returns exactly what the plain one does`() {
        val periods = listOf(sleep(0, 3000), active(3000, 3900), sleep(3900, 9000))
        val hr = calmHr(0, 9000)
        assertEquals(
            SleepStager.bridgeSparseSleep(periods, sparse = true, hr = hr, baseline = baseline),
            SleepStager.bridgeSparseSleepTraced(periods, sparse = true, hr = hr, baseline = baseline).first,
        )
    }

    /**
     * #1657, the other half: hrSleepBandAcross judged on the MEAN, which a single arousal spike drags out
     * of band — the exact statistic confirmSleepWithHR documents as wrong for this, and uses the median
     * for instead. A sustained elevation must still be rejected, or the gate stops discriminating.
     */
    @Test
    fun `a brief spike no longer puts the whole interval out of band, a sustained one still does`() {
        val spiky = calmHr(0, 3540) + calmHr(3541, 3660, bpm = 190)
        assertTrue(SleepStager.hrSleepBandAcross(0, 3660, spiky, baseline))
        val sustained = calmHr(0, 3660, bpm = 110)
        assertFalse(SleepStager.hrSleepBandAcross(0, 3660, sustained, baseline))
    }

    // ── End to end, through detectSleep ──────────────────────────────────────────────────────────
    //
    // The unit cases above pin the bridge. These pin the thing the reporter actually saw: a night with
    // one interruption in it arriving as ONE session instead of a truncated fragment.

    private val dev = "test"
    /** 2025-06-10 00:00:00 UTC. */
    private val refMidnight = 1_749_513_600L
    private fun at(hour: Int, min: Int = 0) = refMidnight + hour * 3_600L + min * 60L

    /** Still gravity at 1/min — constant orientation, so every delta is 0. */
    private fun still(from: Long, toExclusive: Long) =
        (from until toExclusive step 60).map {
            com.noop.data.GravitySample(deviceId = dev, ts = it, x = 0.0, y = 0.0, z = 1.0)
        }

    /** Moving gravity at 1/min — orientation swings every sample, so deltas are large. */
    private fun moving(from: Long, toExclusive: Long) =
        (from until toExclusive step 60).mapIndexed { i, _ -> i }.map { i ->
            val t = from + i * 60L
            if (i % 2 == 0) com.noop.data.GravitySample(deviceId = dev, ts = t, x = 1.0, y = 0.0, z = 0.0)
            else com.noop.data.GravitySample(deviceId = dev, ts = t, x = 0.0, y = 1.0, z = 0.0)
        }

    private fun hr1Hz(from: Long, toExclusive: Long, bpm: Int) =
        (from until toExclusive).map { HrSample(deviceId = dev, ts = it, bpm = bpm) }

    /**
     * A night with a 30-minute gravity dropout early (so the night reads sparse, as a 5/MG's does) and a
     * 15-minute up-and-about in the middle. Before #1657 the active run made the two sleep halves
     * unreachable to the bridge and each half faced the 60-minute floor alone.
     */
    private fun interruptedNight(tripBpm: Int): Pair<List<HrSample>, List<com.noop.data.GravitySample>> {
        val grav = still(at(0), at(0, 30)) +           // 00:00-00:30 asleep
            still(at(1), at(2)) +                       // 00:30-01:00 DROPOUT, then 01:00-02:00 asleep
            moving(at(2), at(2, 15)) +                  // 02:00-02:15 up
            still(at(2, 15), at(6))                     // 02:15-06:00 asleep again
        val hr = hr1Hz(at(0), at(2), 50) +
            hr1Hz(at(2), at(2, 15), tripBpm) +
            hr1Hz(at(2, 15), at(6), 50)
        return hr to grav
    }

    @Test
    fun `a night with one short interruption is detected as a single session`() {
        val (hr, grav) = interruptedNight(tripBpm = 52)
        assertTrue("the fixture must read as sparse", SleepStager.isGravitySparse(grav, hr))
        val sessions = SleepStager.detectSleep(hr = hr, gravity = grav)
        assertEquals("the interruption must not end the night", 1, sessions.size)
        val spanMin = (sessions[0].end - sessions[0].start) / 60.0
        assertTrue("the whole night should survive, got $spanMin min", spanMin > 5 * 60)
    }

    /**
     * The same night with the wearer genuinely up — HR elevated for the whole quarter hour. The bridge
     * must decline, because absorbing that would score wakefulness as sleep: wrong in a new direction and
     * harder to notice than the truncation being fixed.
     */
    @Test
    fun `the same night with a genuinely awake interruption is not bridged into one`() {
        val (hr, grav) = interruptedNight(tripBpm = 110)
        val sessions = SleepStager.detectSleep(hr = hr, gravity = grav)
        val spanMin = sessions.sumOf { (it.end - it.start) / 60.0 }
        assertTrue("an awake interruption must not be absorbed (got ${sessions.size} sessions, $spanMin min)",
            sessions.size != 1 || spanMin < 5 * 60)
    }

    /**
     * The RENDERED line, not just the fields — and deliberately the whole string, byte for byte.
     *
     * The Swift twin asserts this identical literal. Nothing in the tree compares the two languages'
     * trace output automatically (Tools/parity_cases holds one unrelated fixture), so a format change on
     * one side would otherwise diverge in silence and only surface when someone tried to read a capture
     * from the other platform. Pinning the same literal both sides turns that into a failing test on
     * whichever side moved.
     */
    @Test
    fun `the pair line renders exactly as its Swift twin does`() {
        val line = SleepStagerTrace.runLine(
            -1, 0, 0, SleepStagerTrace.Verdict.DROPPED, "sparseBridgePair",
            "pair=0 gapMin=23 activeMin=21 hrInSleepBand=true reason=activeTooLong",
        )
        assertEquals(
            "gate run=-1 spanS=0 DROPPED gate=sparseBridgePair " +
                "pair=0 gapMin=23 activeMin=21 hrInSleepBand=true reason=activeTooLong",
            line,
        )
    }
}
