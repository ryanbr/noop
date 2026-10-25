package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

/**
 * #2517, recorded rather than corrected: a transition day stays 86,400 seconds wide and
 * [AnalyticsEngine.dayWindowSkewLine] names the hour that puts it on.
 *
 * The arithmetic is cross-checked against [LocalDayWindows], which derives the same length from the zone
 * rules instead of from two offsets, so the cheap path and the correct one are held to one answer. Every
 * expectation here is the same string the Swift suite asserts. Swift twin:
 * `AnalyticsEngineDayWindowSkewTests`.
 */
class AnalyticsEngineDayWindowSkewTest {

    /** 363 days a year this says nothing, and saying nothing is what makes it affordable always-on. */
    @Test
    fun anOrdinaryDayEmitsNothing() {
        assertNull(AnalyticsEngine.dayWindowSkewLine("2026-10-24", 7_200L, 7_200L))
        assertNull(AnalyticsEngine.dayWindowSkewLine("2026-06-01", 0L, 0L))
    }

    /**
     * The reported case: Europe/Amsterdam, 2026-10-25, the day #2852 was filed about. CEST (+2) at the
     * day's start, CET (+1) by the time the fixed window ends, so the local day is 25 hours and the
     * window is an hour short of it.
     */
    @Test
    fun theFallBackDayNamesItsExtraHour() {
        assertEquals(
            "day-window-skew day=2026-10-25 realS=90000 windowS=86400 skewMin=60 " +
                "offsetStart=7200 offsetEnd=3600 policy=keep-24h",
            AnalyticsEngine.dayWindowSkewLine("2026-10-25", 7_200L, 3_600L),
        )
    }

    /**
     * And the other direction, where the window runs an hour INTO the next local day. The sign carries
     * it: a reader who only saw a magnitude could not tell which day gained the hour.
     */
    @Test
    fun theSpringForwardDayNamesItsMissingHour() {
        assertEquals(
            "day-window-skew day=2026-03-29 realS=82800 windowS=86400 skewMin=-60 " +
                "offsetStart=3600 offsetEnd=7200 policy=keep-24h",
            AnalyticsEngine.dayWindowSkewLine("2026-03-29", 3_600L, 7_200L),
        )
    }

    /**
     * A 30-minute transition is why the arithmetic is a subtraction rather than a hardcoded 3,600. Lord
     * Howe Island moves by half an hour; a constant would have called this day 24 or 25 hours.
     */
    @Test
    fun aHalfHourTransitionIsReportedAtItsRealSize() {
        assertEquals(
            "day-window-skew day=2026-04-05 realS=88200 windowS=86400 skewMin=30 " +
                "offsetStart=39600 offsetEnd=37800 policy=keep-24h",
            AnalyticsEngine.dayWindowSkewLine("2026-04-05", 39_600L, 37_800L),
        )
    }

    /**
     * The two implementations must agree on the LENGTH. [LocalDayWindows] reads the zone rules; this line
     * subtracts two offsets. The committed oracle pins the zone-rule answers at 90,000 and 82,800
     * seconds, so reproducing those from offsets alone is what makes the cheap path trustworthy.
     *
     * Driven through [LocalDayWindows] itself rather than against literals copied from the oracle: a
     * literal would still pass if the helper and the primitive drifted apart, which is the one thing this
     * test exists to catch.
     */
    @Test
    fun theOffsetArithmeticReproducesTheZoneRuleDayLength() {
        for ((zoneName, day) in listOf(
            "America/New_York" to "2025-11-02",
            "America/New_York" to "2025-03-09",
        )) {
            val zone = ZoneId.of(zoneName)
            val helper = LocalDayWindows(zone = zone, referenceInstant = Instant.ofEpochSecond(2_000_000_000L))
            val parts = day.split("-").map { it.toInt() }
            val date = LocalCalendarDate(year = parts[0], month = parts[1], day = parts[2])
            val window = requireNotNull(helper.window(date)) { "$zoneName $day has no window" }
            val fromZoneRules = window.duration.seconds

            // The same two lookups the engine's call site makes: the offset at the day's start, and the
            // offset where a FIXED 86,400-second window would have ended.
            val offsetAtStart = zone.rules.getOffset(window.start).totalSeconds.toLong()
            val offsetAtFixedEnd = zone.rules.getOffset(window.start.plusSeconds(86_400L)).totalSeconds.toLong()
            val fromOffsets = 86_400L + (offsetAtStart - offsetAtFixedEnd)

            assertEquals(
                "$zoneName $day: offset arithmetic and zone rules must agree on the length",
                fromZoneRules,
                fromOffsets,
            )
            assertNotEquals("$day must be a transition day, or this proves nothing", 86_400L, fromZoneRules)
            val line = requireNotNull(
                AnalyticsEngine.dayWindowSkewLine(day, offsetAtStart, offsetAtFixedEnd),
            )
            assertTrue(
                "the line must report the zone-rule length, not a second opinion: $line",
                line.contains("realS=$fromZoneRules"),
            )
        }
    }
}
