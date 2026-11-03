package com.noop.ui

import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the Today "Last Workouts" feed contract: cross-source dedup (#687 semantics),
 * newest first, capped at four. Guards the duplicate-card bug where a strap recording
 * and its thin Health Connect import both occupied a slot.
 */
class LastWorkoutsFeedTest {

    private fun row(
        deviceId: String,
        start: Long,
        end: Long,
        sport: String,
        source: String,
        avgHr: Int? = null,
        maxHr: Int? = null,
        strain: Double? = null,
        kcal: Double? = null,
    ) = WorkoutRow(
        deviceId = deviceId, startTs = start, endTs = end, sport = sport, source = source,
        durationS = (end - start).toDouble(), energyKcal = kcal, avgHr = avgHr, maxHr = maxHr,
        strain = strain,
    )

    @Test
    fun collapsesLiveAndImportTwin_keepsRicher_newestFirst() {
        // The observed bug: Badminton recorded live on the strap AND imported thin from
        // Health Connect. Plus three older distinct workouts; the union is 5 rows but
        // only 4 real activities — all four must surface, richer twin kept.
        val liveBadminton = row("my-whoop", 10_000, 13_000, "Badminton", "my-whoop",
            avgHr = 150, maxHr = 180, strain = 12.0, kcal = 1215.0)
        val hcBadminton = row("health-connect", 10_060, 12_940, "Badminton", "health-connect",
            kcal = 1100.0)
        val run = row("health-connect", 8_000, 9_000, "Running", "health-connect")
        val lift = row("my-whoop", 6_000, 7_000, "Lifting", "my-whoop", avgHr = 110)
        val walk = row("apple-health", 4_000, 5_000, "Walking", "apple-health")

        val feed = lastWorkoutsFeed(listOf(hcBadminton, run, liveBadminton, lift, walk))

        assertEquals(4, feed.size)
        // Newest first.
        assertEquals(listOf(10_000L, 8_000L, 6_000L, 4_000L), feed.map { it.startTs })
        // The surviving Badminton is the richer strap row, not the thin import.
        assertEquals("my-whoop", feed[0].source)
        assertEquals(150, feed[0].avgHr)
    }

    @Test
    fun capsAtFourNewest() {
        val rows = (1..6).map { i ->
            row("my-whoop", i * 1_000L, i * 1_000L + 500, "Sport$i", "my-whoop")
        }
        val feed = lastWorkoutsFeed(rows)
        assertEquals(4, feed.size)
        assertEquals(listOf(6_000L, 5_000L, 4_000L, 3_000L), feed.map { it.startTs })
    }

    /** The user-edited feed length (Today Customise) caps the same dedup'd, newest-first feed. */
    @Test
    fun explicitLimitCapsFeed() {
        val rows = (1..6).map { i ->
            row("my-whoop", i * 1_000L, i * 1_000L + 500, "Sport$i", "my-whoop")
        }
        val feed = lastWorkoutsFeed(rows, limit = 2)
        assertEquals(listOf(6_000L, 5_000L), feed.map { it.startTs })
        // An out-of-range saved value is clamped, never zero or unbounded.
        assertEquals(1, lastWorkoutsFeed(rows, limit = 0).size)
        assertEquals(6, lastWorkoutsFeed(rows, limit = 99).size)
    }

    @Test
    fun emptyInputYieldsEmptyFeed() {
        assertTrue(lastWorkoutsFeed(emptyList()).isEmpty())
    }
}
