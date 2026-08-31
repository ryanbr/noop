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
}
