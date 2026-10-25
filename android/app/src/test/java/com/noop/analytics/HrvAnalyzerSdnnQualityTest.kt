package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HrvAnalyzerSdnnQualityTest {
    private fun sdnnQualityFixtureRows(offset: Long = 0L): List<RrInterval> =
        List(300) { RrInterval("synthetic", offset + it, 1000 + (it % 4) * 10) }

    @Test
    fun cleanSegmentKeepsItsSampleSdnn() {
        assertEquals(11.199020501841618, HrvAnalyzer.sdnnIndex(sdnnQualityFixtureRows())!!, 1e-12)
    }

    @Test
    fun duplicateDeliveriesCannotSupplyDailySdnn() {
        val clean = sdnnQualityFixtureRows()
        val duplicated = clean.flatMap { listOf(it, it) }
        assertNull(HrvAnalyzer.sdnnIndex(duplicated))
        val banked = clean.mapIndexed { index, beat ->
            RrInterval("synthetic", (index / 6 * 6).toLong(), beat.rrMs)
        }
        val badLater = sdnnQualityFixtureRows(300L).flatMap { listOf(it, it) }
        val cases = listOf(
            "clean" to clean, "duplicate" to duplicated, "banked" to banked,
            "mixed" to (clean + badLater), "offset" to sdnnQualityFixtureRows(1_700_000_000L),
            "reversed" to clean.reversed(), "tooFew" to clean.take(19), "empty" to emptyList()
        )
        val actual = cases.joinToString("\n") { (name, rows) ->
            val bits = HrvAnalyzer.sdnnIndex(rows)?.let { java.lang.Long.toHexString(it.toRawBits()) } ?: "nil"
            "$name=$bits"
        }
        // Copied verbatim from the real Swift HRVAnalyzer's stdout, 7 Oct 2026, over these eight cases.
        // Raw Double bits pin stored-value parity rather than accepting an approximately equal number.
        assertEquals("""
            clean=402665e603e54959
            duplicate=nil
            banked=nil
            mixed=402665e603e54959
            offset=402665e603e54959
            reversed=402665e603e54959
            tooFew=nil
            empty=nil
        """.trimIndent(), actual)
    }

    @Test
    fun bankedIntervalsCannotSupplyDailySdnn() {
        val banked = sdnnQualityFixtureRows().mapIndexed { index, beat ->
            RrInterval("synthetic", (index / 6 * 6).toLong(), beat.rrMs)
        }
        assertNull(HrvAnalyzer.sdnnIndex(banked))
    }

    @Test
    fun refusedSegmentDoesNotDiscardCleanSegment() {
        val clean = sdnnQualityFixtureRows()
        val bad = sdnnQualityFixtureRows(300L).flatMap { listOf(it, it) }
        assertEquals(11.199020501841618, HrvAnalyzer.sdnnIndex(clean + bad)!!, 1e-12)
    }
}
