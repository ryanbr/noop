package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2252: the ticks x10 defect (#2239) filed whole sessions in the past, and the store keeps no
 * ring-time, so nothing there can say which rows they were. The epoch a row implies
 * (`utc - ringTs/10`) separates a mis-anchored session from an honest one.
 *
 * Swift twin: `OuraRingEpochScanTests.swift`.
 */
class OuraRingEpochScanTest {

    /** The ring really runs at 9.94 to 10.25 ticks per second, so a correct session's epoch drifts. */
    private fun session(
        bootUnix: Long,
        startTicks: Long,
        count: Int,
        tickRate: Double = 10.25,
        shiftSeconds: Long = 0,
    ): List<Pair<Long, Long>> = (0 until count).map { i ->
        val rt = startTicks + i * 3_000L
        rt to (bootUnix + (rt / tickRate).toLong() - shiftSeconds)
    }

    @Test
    fun driftWithinOneBootStaysOneCluster() {
        val rows = session(1_789_000_000L, 3_000L, 400)
        assertEquals(1, OuraRingEpochScan.cluster(rows).size)
    }

    /** The #2239 shape: an x10-anchored session implies an epoch 0.9 x anchorTicks earlier. */
    @Test
    fun anX10AnchoredSessionSeparatesFromTheHonestOne() {
        val boot = 1_789_000_000L
        val anchorTicks = 4_006_498L
        val shift = (0.9 * anchorTicks).toLong()
        val rows = session(boot, 3_000L, 300) + session(boot, anchorTicks, 50, shiftSeconds = shift)

        val clusters = OuraRingEpochScan.cluster(rows)

        assertEquals("one honest boot and one mis-anchored session", 2, clusters.size)
        assertEquals(300, clusters[0].rows)
        assertEquals(50, clusters[1].rows)
        val gapDays = (clusters[0].epochUnix - clusters[1].epochUnix).toDouble() / 86_400
        assertTrue("gap $gapDays should be the 41.7-day signature", kotlin.math.abs(gapDays - 41.7) < 0.5)
        assertTrue(
            "the mis-anchored rows are the ones filed in the past",
            clusters[1].lastStoredUtc < clusters[0].firstStoredUtc,
        )
    }

    /** A healthy ring says nothing, so a healthy report is byte-unchanged by this existing. */
    @Test
    fun aHealthyRingProducesNoLine() {
        val rows = session(1_789_000_000L, 3_000L, 50)
        assertEquals(null, OuraRingEpochScan.summaryLine(OuraRingEpochScan.cluster(rows)))
        assertEquals(null, OuraRingEpochScan.summaryLine(emptyList()))
    }

    /** The line carries the gap, the row counts and the stored span. */
    @Test
    fun theLineCarriesTheGapAndTheStoredSpan() {
        val boot = 1_789_000_000L
        val anchorTicks = 4_006_498L
        val rows = session(boot, 3_000L, 300) +
            session(boot, anchorTicks, 50, shiftSeconds = (0.9 * anchorTicks).toLong())

        val line = OuraRingEpochScan.summaryLine(OuraRingEpochScan.cluster(rows))

        assertTrue(line != null)
        assertTrue(line!!.startsWith("ouraRingEpoch clusters=2 "))
        assertTrue(line.contains("rows=300"))
        assertTrue(line.contains("rows=50"))
        // "41." rather than "41.7": each cluster's epoch is its MEDIAN and the runs drift by different
        // amounts, so the printed decimal moves. The numeric gap is pinned with a tolerance in
        // anX10AnchoredSessionSeparatesFromTheHonestOne; this asserts the line CARRIES it.
        assertTrue("the ticks x10 signature: $line", line.contains("gapDays=41."))
        assertTrue(line.contains("stored="))
    }

    @Test
    fun unanchoredRowsAreDroppedRatherThanGivenAnEpoch() {
        assertTrue(OuraRingEpochScan.cluster(listOf(0L to 1_789_000_000L, 0L to 1_789_000_060L)).isEmpty())
        val mixed = listOf(0L to 1_789_000_000L, 3_000L to 1_789_000_300L)
        assertEquals(listOf(1), OuraRingEpochScan.cluster(mixed).map { it.rows })
    }




    /** Two clusters sharing a median epoch must order identically on both platforms. */
    @Test
    fun clustersWithTheSameEpochAreOrderedDeterministically() {
        val epoch = 1_789_000_000L
        val rows = (0 until 5).map { i ->
            val t = 3_000L + i * 60L; t to (epoch + t / 10)
        } + (0 until 3).map { i ->
            val t = 9_000_000L + i * 60L; t to (epoch + t / 10)
        }

        val once = OuraRingEpochScan.cluster(rows)
        val again = OuraRingEpochScan.cluster(rows.reversed())

        assertEquals("order in must not change order out", once, again)
        if (once.size > 1) {
            assertTrue("an epoch tie breaks on row count", once[0].rows >= once[1].rows)
        }
    }

    @Test
    fun emptyInputYieldsNoClusters() {
        assertTrue(OuraRingEpochScan.cluster(emptyList()).isEmpty())
    }

    /** The sidecars are appended per connection, so the result must not depend on arrival order. */
    @Test
    fun resultDoesNotDependOnInputOrder() {
        val boot = 1_789_000_000L
        val rows = session(boot, 3_000L, 40) + session(boot, 4_006_498L, 20, shiftSeconds = 3_605_848L)
        assertEquals(OuraRingEpochScan.cluster(rows), OuraRingEpochScan.cluster(rows.reversed()))
    }

    /** The gap closes against the PREVIOUS row, so a steady drift past tolerance stays one cluster. */
    @Test
    fun aSteadyDriftPastToleranceStillClustersAsOne() {
        val boot = 1_789_000_000L
        val rows = (0 until 12).map { i ->
            val ticks = 3_000L + i * 3_000L
            ticks to (boot + ticks / 10 + i * 3_600L)
        }
        assertEquals(1, OuraRingEpochScan.cluster(rows).size)
    }
}
