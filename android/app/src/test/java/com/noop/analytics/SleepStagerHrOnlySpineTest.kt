package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The HR-only Stage-0 spine (#1801), for a strap that streams heart rate but banks no motion.
 *
 * Every expectation below is the Swift twin's OWN output, produced by compiling
 * `SleepStager.hrOnlySleepRuns` standalone (`swiftc -O twin.swift main.swift`) over this exact case
 * list and pasted verbatim — not read off the Kotlin implementation. The package's XCTest twin
 * `SleepStagerHrOnlySpineTests` asserts the same values on Apple; the harness exists because the test
 * binary cannot link GRDB's sqlite3 on Linux, so the assertions could not otherwise be run here.
 *
 * Baseline 60 throughout, so the band is `60 * hrSleepBandMult` = 63.0 bpm inclusive. Samples land every
 * 10 s, six to a 60 s epoch.
 */
class SleepStagerHrOnlySpineTest {

    private fun hr(epoch: Int, bpms: List<Int>): List<HrSample> {
        val out = ArrayList<HrSample>()
        bpms.forEachIndexed { i, bpm ->
            val base = (epoch + i).toLong() * 60L
            repeat(6) { k -> out.add(HrSample(deviceId = "d", ts = base + k * 10L, bpm = bpm)) }
        }
        return out
    }

    private fun tuples(p: List<SleepStager.Period>): List<String> =
        p.map { "${it.stage} ${it.start}-${it.end}" }

    @Test
    fun `no baseline or no hr yields nothing`() {
        assertTrue(SleepStager.hrOnlySleepRuns(hr(1000, listOf(55)), null).isEmpty())
        assertTrue(SleepStager.hrOnlySleepRuns(hr(1000, listOf(55)), 0.0).isEmpty())
        assertTrue(SleepStager.hrOnlySleepRuns(emptyList(), 60.0).isEmpty())
    }

    @Test
    fun `all in band is one sleep run`() {
        assertEquals(
            listOf("sleep 60000-60170"),
            tuples(SleepStager.hrOnlySleepRuns(hr(1000, listOf(55, 55, 55)), 60.0)),
        )
    }

    @Test
    fun `all out of band is one active run`() {
        assertEquals(
            listOf("active 60000-60170"),
            tuples(SleepStager.hrOnlySleepRuns(hr(1000, listOf(90, 90, 90)), 60.0)),
        )
    }

    @Test
    fun `sleep active sleep segments into three`() {
        assertEquals(
            listOf("sleep 60000-60110", "active 60120-60170", "sleep 60180-60290"),
            tuples(SleepStager.hrOnlySleepRuns(hr(1000, listOf(55, 55, 90, 55, 55)), 60.0)),
        )
    }

    /**
     * A gap wider than [SleepStager.maxGapMin] breaks a run even when the class never changes — the same
     * rule [SleepStager.buildRuns] applies to a gravity gap.
     */
    @Test
    fun `gap wider than maxGap breaks a same-class run`() {
        assertEquals(
            listOf("sleep 60000-60050", "sleep 61800-61850"),
            tuples(SleepStager.hrOnlySleepRuns(hr(1000, listOf(55)) + hr(1030, listOf(55)), 60.0)),
        )
    }

    /**
     * The band test is a MEDIAN, so one arousal spike inside an epoch cannot flip it to active — the
     * property [SleepStager.hrSleepBandAcross] documents, asserted here on the epoch reduction.
     */
    @Test
    fun `one spike in an epoch does not flip it`() {
        val samples = hr(1000, listOf(55)).toMutableList()
        samples[5] = samples[5].copy(bpm = 190)
        assertEquals(
            listOf("sleep 60000-60050"),
            tuples(SleepStager.hrOnlySleepRuns(samples, 60.0)),
        )
    }

    /**
     * A run's `end` is the last SAMPLE seen, not the final epoch's start. Pinned because reading the
     * epoch start reports every run one epoch short of the data it covers — silently, and straight into
     * the caller's minimum-duration gate. Three 60 s epochs of samples laid every 10 s end at 60170.
     */
    @Test
    fun `run end is the last sample not the epoch start`() {
        val runs = SleepStager.hrOnlySleepRuns(hr(1000, listOf(55, 55, 55)), 60.0)
        assertEquals(60170L, runs.first().end)
        assertEquals(170L, runs.first().end - runs.first().start)
    }

    /** The band is inclusive: 63 is `60 * 1.05` exactly. */
    @Test
    fun `band boundary is inclusive`() {
        assertEquals(
            listOf("sleep 60000-60050"),
            tuples(SleepStager.hrOnlySleepRuns(hr(1000, listOf(63)), 60.0)),
        )
        assertEquals(
            listOf("active 60000-60050"),
            tuples(SleepStager.hrOnlySleepRuns(hr(1000, listOf(64)), 60.0)),
        )
    }
}
