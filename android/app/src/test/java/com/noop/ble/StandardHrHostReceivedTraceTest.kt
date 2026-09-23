package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The host-received lines, summarised - the twin of Swift `LivePersistTrace.StandardHRHostReceivedTrace`.
 *
 * The per-sample line was 52.8 percent of one gym session's strap log (3,009 of 5,704 lines on 22 Sep 2026), which
 * is what decides how much history the on-disk log (#2386) holds. The two `oracle...` tests pin byte-identity with
 * iOS: their expected text is the Swift trace's own output for the same scenario, pasted verbatim, never written
 * by hand.
 */
class StandardHrHostReceivedTraceTest {

    private fun routine(second: Int) = StandardHrHostReceivedTrace.Sample(
        hostUnixSeconds = second, acceptedHrRows = 1, acceptedRrRows = 2,
        rejectedHrRows = 0, rejectedRrRows = 0, pendingHrRows = 1, pendingRrRows = 2,
    )

    /** A minute of a streaming strap: one line, carrying what the sixty said. */
    @Test
    fun oracleAQuietMinuteAsIOSRendersIt() {
        val trace = StandardHrHostReceivedTrace()
        val lines = ArrayList<String>()
        for (second in 0..60) lines += trace.record(routine(second), detailed = false)
        lines += trace.close()
        assertEquals(ORACLE_QUIET, lines.joinToString("\n"))
    }

    /** A refusal is written the moment it happens, counted in the window, and a stall shows as the widest gap. */
    @Test
    fun oracleARefusalAndAStallAsIOSRendersThem() {
        val trace = StandardHrHostReceivedTrace()
        val lines = ArrayList<String>()
        for (second in 0 until 20) lines += trace.record(routine(second), detailed = false)
        lines += trace.record(
            StandardHrHostReceivedTrace.Sample(
                hostUnixSeconds = 20, acceptedHrRows = 0, acceptedRrRows = 1,
                rejectedHrRows = 1, rejectedRrRows = 2, pendingHrRows = 7, pendingRrRows = 9,
            ),
            detailed = false,
        )
        for (second in listOf(21, 22, 40)) lines += trace.record(routine(second), detailed = false)
        lines += trace.close()
        assertEquals(ORACLE_MIXED, lines.joinToString("\n"))
    }

    /** With a Test Centre mode on, every sample is written in full and the window still lands. */
    @Test
    fun detailWritesEverySampleAndStillSummarises() {
        val trace = StandardHrHostReceivedTrace()
        val lines = ArrayList<String>()
        for (second in 0..60) lines += trace.record(routine(second), detailed = true)
        assertEquals(61, lines.count { it.contains("hostUnixSec=") })
        assertEquals(1, lines.count { it.contains("summary") })
    }

    /** The size of the thing: an hour of a streaming strap. */
    @Test
    fun anHourOfStreamingIsSixtyLines() {
        val trace = StandardHrHostReceivedTrace()
        var lines = 0
        for (second in 0 until 3_600) lines += trace.record(routine(second), detailed = false).size
        lines += trace.close().size
        assertEquals(60, lines)
    }

    private companion object {
        /** Swift oracle output: 61 routine samples a second apart, then close(). */
        val ORACLE_QUIET = """standard-hr transport host-received summary windowSec=59 samples=60 gapMaxSec=1 acceptedHRRows=60 acceptedRRRows=120 rejectedHRRows=0 rejectedRRRows=0 pendingHRRows=1 pendingRRRows=2
standard-hr transport host-received summary windowSec=0 samples=1 gapMaxSec=1 acceptedHRRows=1 acceptedRRRows=2 rejectedHRRows=0 rejectedRRRows=0 pendingHRRows=1 pendingRRRows=2"""

        /** Swift oracle output: a refused sample among routine ones, then an 18-second gap, then close(). */
        val ORACLE_MIXED = """standard-hr transport host-received hostUnixSec=20 acceptedHRRows=0 acceptedRRRows=1 rejectedHRRows=1 rejectedRRRows=2 pendingHRRows=7 pendingRRRows=9
standard-hr transport host-received summary windowSec=40 samples=24 gapMaxSec=18 acceptedHRRows=23 acceptedRRRows=47 rejectedHRRows=1 rejectedRRRows=2 pendingHRRows=1 pendingRRRows=2"""
    }

    /**
     * #2405: the stall that crosses a window boundary is the one a reader is looking for.
     *
     * A gap of a minute or more forces the roll on the very next sample, so before this it fell between
     * two windows and was counted in neither: gapMaxSec could only ever describe stalls SHORTER than the
     * window. Twin of the Swift test.
     */
    @Test fun aStallLongerThanTheWindowIsReportedByTheWindowItOpens() {
        val trace = StandardHrHostReceivedTrace()
        val lines = mutableListOf<String>()
        for (t in 0 until 30) lines += trace.record(routine(1_000 + t), detailed = false)
        lines += trace.record(routine(1_000 + 29 + 120), detailed = false)
        lines += trace.close()

        assertEquals(2, lines.size)
        assertTrue(lines[0], lines[0].contains("windowSec=29 samples=30 gapMaxSec=1"))
        assertTrue(lines[1], lines[1].contains("samples=1 gapMaxSec=120"))
    }

    /** A clock that steps backwards across the boundary has no honest span, so none is claimed. */
    @Test fun aBackwardsClockAcrossTheBoundarySeedsNoGap() {
        val trace = StandardHrHostReceivedTrace()
        val lines = mutableListOf<String>()
        for (t in 0 until 5) lines += trace.record(routine(1_000 + t), detailed = false)
        lines += trace.record(routine(900), detailed = false)
        lines += trace.close()

        assertTrue(lines.last(), lines.last().contains("gapMaxSec=0"))
    }

    /** close() is a disconnect, a background flush or a termination, each accounting for the silence on
     *  its own. A stall measured across one would be reported twice. */
    @Test fun aGapAcrossACloseIsNotSeeded() {
        val trace = StandardHrHostReceivedTrace()
        trace.record(routine(1_000), detailed = false)
        trace.close()
        val lines = mutableListOf<String>()
        lines += trace.record(routine(1_000 + 600), detailed = false)
        lines += trace.close()

        assertTrue(lines.last(), lines.last().contains("gapMaxSec=0"))
    }
}
