package com.noop.analytics

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class StepsDetailDensityTest {
    private val projector = StepsDetailDensity::project

    private fun loadOracle(): JSONObject {
        val stream = javaClass.classLoader!!.getResourceAsStream(ORACLE_RESOURCE)
            ?: error("committed oracle $ORACLE_RESOURCE not on the test classpath")
        return JSONObject(stream.bufferedReader().use { it.readText() })
    }

    @Test
    fun kotlinProjectorAssertsTheSharedFixture() {
        val oracle = loadOracle()
        assertEquals(1, oracle.getInt("schemaVersion"))
        assertFalse(oracle.getString("note").isEmpty())
        val cases = oracle.getJSONArray("cases")
        assertEquals(11, cases.length())
        assertEquals(
            setOf("W", "2W", "3W", "M", "3M", "6M", "1Y", "ALL"),
            (0 until cases.length()).map { cases.getJSONObject(it).getString("range") }.toSet(),
        )

        for (index in 0 until cases.length()) {
            val fixture = cases.getJSONObject(index)
            val id = fixture.getString("id")
            val input = fixture.getJSONArray("readings")
            val readings = (0 until input.length()).map {
                input.getJSONObject(it).let { row ->
                    StepsDetailReading(day = row.getString("day"), value = row.getDouble("value"))
                }
            }
            val actual = projector(
                readings,
                StepsDetailRange.entries.first { it.label == fixture.getString("range") },
                fixture.getString("anchorDay"),
            )
            val expected = fixture.getJSONArray("expected")
            assertEquals(id, expected.length(), actual.size)
            for (bucketIndex in 0 until expected.length()) {
                val want = expected.getJSONObject(bucketIndex)
                val bucket = actual[bucketIndex]
                assertEquals(id, want.getString("key"), bucket.key)
                assertEquals(id, want.getString("displayDay"), bucket.displayDay)
                assertEquals(id, want.getDouble("sum"), bucket.sum, 0.000_000_1)
                assertEquals(id, want.getInt("observedDayCount"), bucket.observedDayCount)
                assertEquals(id, want.getInt("mean"), bucket.mean)
            }
        }
    }

    @Test
    fun invalidExplicitAnchorProducesNoBuckets() {
        val readings = listOf(StepsDetailReading(day = "2024-02-29", value = 100.0))
        assertEquals(
            emptyList<StepsDetailBucket>(),
            projector(readings, StepsDetailRange.WEEK, "2023-02-29"),
        )
    }

    @Test
    fun latestValidReadingIsTheDefaultAnchor() {
        val readings = listOf(
            StepsDetailReading(day = "2024-01-01", value = 1.0),
            StepsDetailReading(day = "2024-01-20", value = 2.0),
            StepsDetailReading(day = "invalid", value = 999.0),
        )
        assertEquals(
            listOf(StepsDetailBucket("2024-01-20", "2024-01-20", 2.0, 1, 2)),
            projector(readings, StepsDetailRange.WEEK, null),
        )
    }

    private companion object {
        const val ORACLE_RESOURCE = "steps_detail_density_oracle.json"
    }
}
