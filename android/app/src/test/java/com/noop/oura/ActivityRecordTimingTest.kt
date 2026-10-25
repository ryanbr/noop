package com.noop.oura

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [OuraActivityRecordTiming] against the SHARED fixture the Swift twin also asserts
 * (`oura_met_record_timing_oracle.json`, read by `ActivityRecordTimingTests.swift` through a
 * repo-root walk, #2242).
 *
 * One committed file, read by both suites, so neither platform can move the rule without the other
 * going red. The fixture is generated from the Swift enum compiled standalone; regenerate it from
 * Swift and never hand-edit a number in it.
 */
class ActivityRecordTimingTest {

    private fun loadOracle(): JSONObject {
        val stream = javaClass.classLoader!!.getResourceAsStream(ORACLE_RESOURCE)
            ?: error("committed oracle $ORACLE_RESOURCE not on the test classpath")
        return JSONObject(stream.bufferedReader().use { it.readText() })
    }

    @Test
    fun kotlinTimingAssertsTheSharedFixture() {
        val oracle = loadOracle()
        assertEquals(1, oracle.getInt("schemaVersion"))
        assertFalse(oracle.getString("note").isEmpty())
        val cases = oracle.getJSONArray("cases")
        assertEquals(11, cases.length())

        val ids = (0 until cases.length()).map { cases.getJSONObject(it).getString("id") }.toSet()
        // The shapes that must be in the contract: if one is dropped the fixture stops covering it.
        assertTrue(
            ids.containsAll(
                listOf(
                    "single_sample_record", "typical_26_sample_record",
                    "straddles_local_midnight", "ends_exactly_on_local_midnight",
                    "two_minute_cadence", "empty_record", "zero_epoch",
                ),
            ),
        )

        for (index in 0 until cases.length()) {
            val fixture = cases.getJSONObject(index)
            val id = fixture.getString("id")
            val endUtc = fixture.getLong("endUtc")
            val sampleCount = fixture.getInt("sampleCount")
            val epochSeconds = fixture.getInt("epochSeconds")
            val wanted = fixture.getJSONArray("expectedStarts")
            val expected = (0 until wanted.length()).map { wanted.getLong(it) }

            val actual = OuraActivityRecordTiming.sampleStarts(endUtc, sampleCount, epochSeconds)
            assertEquals(id, expected, actual)

            // Per-sample accessor must agree with the bulk one, index for index.
            expected.forEachIndexed { sampleIndex, start ->
                assertEquals(
                    "$id: sampleStart(index=$sampleIndex)",
                    start,
                    OuraActivityRecordTiming.sampleStart(endUtc, sampleCount, sampleIndex, epochSeconds),
                )
            }
        }
    }

    /**
     * The property the fan-out exists for: the record timestamp is the EXCLUSIVE end of the span, the
     * samples are contiguous and ascending, and the last one ends exactly on the timestamp.
     */
    @Test
    fun samplesAreContiguousAndEndOnTheRecordTimestamp() {
        val endUtc = 1_755_208_800L
        for (sampleCount in 1..40) {
            for (epoch in listOf(30, 60, 120, 300)) {
                val starts = OuraActivityRecordTiming.sampleStarts(endUtc, sampleCount, epoch)
                assertEquals(sampleCount, starts.size)
                assertEquals(endUtc - sampleCount.toLong() * epoch, starts.first())
                assertEquals(
                    "the last sample must end ON the record timestamp",
                    endUtc,
                    starts.last() + epoch,
                )
                assertFalse("the timestamp itself is never a sample start", starts.contains(endUtc))
                starts.zipWithNext { a, b ->
                    assertEquals("samples must be exactly one epoch apart", epoch.toLong(), b - a)
                }
            }
        }
    }

    /**
     * Reading FORWARD from the timestamp is the rule this helper exists to replace (23 % exact minute
     * matches against Oura's export, vs 85 % reading back). Pin the direction so a "simplification"
     * that flips it fails here rather than on a wearer's day boundary.
     */
    @Test
    fun directionIsBackwardFromTheTimestampNotForward() {
        val starts = OuraActivityRecordTiming.sampleStarts(1_000_000L, 3, 60)
        assertEquals(listOf(999_820L, 999_880L, 999_940L), starts)
        assertNotEquals(listOf(1_000_000L, 1_000_060L, 1_000_120L), starts)
    }

    @Test
    fun degenerateShapesPlaceNothing() {
        assertEquals(emptyList<Long>(), OuraActivityRecordTiming.sampleStarts(100L, 0, 60))
        assertEquals(emptyList<Long>(), OuraActivityRecordTiming.sampleStarts(100L, -3, 60))
        assertEquals(emptyList<Long>(), OuraActivityRecordTiming.sampleStarts(100L, 5, 0))
        assertEquals(emptyList<Long>(), OuraActivityRecordTiming.sampleStarts(100L, 5, -60))
    }

    private companion object {
        const val ORACLE_RESOURCE = "oura_met_record_timing_oracle.json"
    }
}
