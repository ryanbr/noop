package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * The round-time x-axis ticks (prototype hr-chart-time-axis). The Today HR axis used to label the
 * data extent's own endpoints ("00:05 / 10:10 / Now"); chartTimeTicks instead emits fixed round
 * wall-clock ticks chosen by the visible span, DST-safe via java.time. Pure + clock-free, so these
 * lock the interval choice, the round alignment, midnight crossing, and the spring-forward dedupe.
 */
class ChartTimeTicksTest {

    private val kyiv = ZoneId.of("Europe/Kyiv")

    private fun at(y: Int, mo: Int, d: Int, h: Int, mi: Int, zone: ZoneId = kyiv): Long =
        ZonedDateTime.of(y, mo, d, h, mi, 0, 0, zone).toEpochSecond()

    @Test fun aFullDayTicksEverySixHoursOnRoundTimes() {
        val ticks = chartTimeTicks(at(2026, 7, 10, 0, 5), at(2026, 7, 10, 23, 40), kyiv)
        assertEquals(listOf("06:00", "12:00", "18:00"), ticks.map { it.second })
        // Tick instants are the labelled wall-clock times, not offsets from the data start.
        assertEquals(at(2026, 7, 10, 6, 0), ticks.first().first)
    }

    @Test fun twelveHoursTicksEveryThreeHours() {
        val ticks = chartTimeTicks(at(2026, 7, 10, 8, 12), at(2026, 7, 10, 20, 12), kyiv)
        assertEquals(listOf("09:00", "12:00", "15:00", "18:00"), ticks.map { it.second })
    }

    @Test fun sixHoursTicksEveryTwoHours() {
        val ticks = chartTimeTicks(at(2026, 7, 10, 9, 30), at(2026, 7, 10, 15, 30), kyiv)
        assertEquals(listOf("10:00", "12:00", "14:00"), ticks.map { it.second })
    }

    @Test fun threeHoursTicksEveryHour() {
        val ticks = chartTimeTicks(at(2026, 7, 10, 13, 10), at(2026, 7, 10, 16, 10), kyiv)
        assertEquals(listOf("14:00", "15:00", "16:00"), ticks.map { it.second })
    }

    @Test fun oneHourTicksEveryQuarterHour() {
        val ticks = chartTimeTicks(at(2026, 7, 10, 14, 5), at(2026, 7, 10, 15, 5), kyiv)
        assertEquals(listOf("14:15", "14:30", "14:45", "15:00"), ticks.map { it.second })
    }

    @Test fun thirtyMinutesTicksEveryFiveMinutes() {
        val ticks = chartTimeTicks(at(2026, 7, 10, 14, 2), at(2026, 7, 10, 14, 32), kyiv)
        assertEquals(listOf("14:05", "14:10", "14:15", "14:20", "14:25", "14:30"), ticks.map { it.second })
    }

    @Test fun tenMinutesTicksEveryTwoMinutes() {
        val ticks = chartTimeTicks(at(2026, 7, 10, 14, 1), at(2026, 7, 10, 14, 11), kyiv)
        assertEquals(listOf("14:02", "14:04", "14:06", "14:08", "14:10"), ticks.map { it.second })
    }

    @Test fun fiveMinutesTicksEveryMinute() {
        val ticks = chartTimeTicks(at(2026, 7, 10, 14, 0, 30), at(2026, 7, 10, 14, 5, 30), kyiv)
        assertEquals(listOf("14:01", "14:02", "14:03", "14:04", "14:05"), ticks.map { it.second })
    }

    @Test fun aWindowCrossingMidnightLabelsMidnightAsZeroZero() {
        // Rolling 24h ending mid-morning: the previous day's evening ticks, then "00:00", then today's.
        val ticks = chartTimeTicks(at(2026, 7, 9, 10, 30), at(2026, 7, 10, 10, 30), kyiv)
        assertTrue(ticks.map { it.second }.contains("00:00"))
        assertEquals(listOf("12:00", "18:00", "00:00", "06:00"), ticks.map { it.second })
    }

    @Test fun emptyAndInvertedWindowsYieldNoTicks() {
        assertTrue(chartTimeTicks(0L, 0L, kyiv).isEmpty())
        assertTrue(chartTimeTicks(100L, 50L, kyiv).isEmpty())
    }

    @Test fun springForwardKeepsLabelsRoundAndUndoubled() {
        // New York 2026-03-08: 02:00 wall clock jumps to 03:00. An hourly-ticking window over the
        // gap resolves the skipped 02:00 to the same instant as 03:00; the dedupe keeps ONE tick,
        // labelled with the wall-clock time that actually exists.
        val ny = ZoneId.of("America/New_York")
        val ticks = chartTimeTicks(at(2026, 3, 8, 0, 30, ny), at(2026, 3, 8, 3, 30, ny), ny)
        assertEquals(listOf("01:00", "03:00"), ticks.map { it.second })
        val epochs = ticks.map { it.first }
        assertEquals(epochs.distinct(), epochs)                       // dedup across the gap
        assertEquals(epochs.sorted(), epochs)                         // still monotonic
    }

    @Test fun timestampFractionInterpolatesBetweenBucketTimestamps() {
        val ts = listOf(0L, 100L, 200L, 400L)
        assertEquals(0f, timestampFraction(ts, 0L)!!, 1e-6f)
        assertEquals(1f, timestampFraction(ts, 400L)!!, 1e-6f)
        // Halfway between buckets 1 and 2 → fractional index 1.5 of 3.
        assertEquals(0.5f, timestampFraction(ts, 150L)!!, 1e-6f)
        // A gap (200→400) still interpolates within its own segment: 300 → index 2.5 of 3.
        assertEquals(2.5f / 3f, timestampFraction(ts, 300L)!!, 1e-6f)
        // Outside the extent, and degenerate lists, map to nothing rather than an edge pin.
        assertEquals(null, timestampFraction(ts, -1L))
        assertEquals(null, timestampFraction(ts, 401L))
        assertEquals(null, timestampFraction(listOf(5L), 5L))
    }
}
