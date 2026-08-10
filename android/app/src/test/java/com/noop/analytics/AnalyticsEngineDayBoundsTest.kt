package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the analyzeDay hot-path optimization (#996): the integer UTC-bounds membership check that replaced
 * the per-sample `dayString(ts, offsetSec) == day` DateFormatter must be BYTE-IDENTICAL to it. If the two
 * ever diverge, samples get attributed to the wrong calendar day (wrong step / calorie / Effort totals), so
 * this sweeps timestamps densely across BOTH midnight edges at a range of fixed offsets — including the
 * FRACTIONAL ones (+5:30 Kolkata, +5:45 Kathmandu, −9:30 Marquesas, −3:30 Newfoundland) — and asserts the two
 * agree at every point. The macOS twin is `AnalyticsEngineDayBoundsTests` (same anchor, same prime step, same
 * offsets) so the cross-platform golden vectors stay in lockstep.
 */
class AnalyticsEngineDayBoundsTest {

    // --- Membership equivalence sweep -----------------------------------------

    @Test fun integerBoundsMatchDayStringAcrossMidnightAndOffsets() {
        val anchor = 1_700_000_000L  // 2023-11-14T22:13:20Z
        val offsets = listOf(
            0L,
            -4 * 3600L, 5 * 3600L, 13 * 3600L, -12 * 3600L, 14 * 3600L,
            5 * 3600L + 1800L,      // +5:30 Kolkata
            5 * 3600L + 2700L,      // +5:45 Kathmandu
            -(9 * 3600L + 1800L),   // −9:30 Marquesas
            -(3 * 3600L + 1800L),   // −3:30 Newfoundland
        )
        for (off in offsets) {
            val day = AnalyticsEngine.dayString(anchor, off)
            val start = AnalyticsEngine.dayStartUtcSeconds(day)
            // ±28 h around the anchor at a prime step, so both midnight edges of `day` are crossed densely
            // and never in phase with the day grid.
            var ts = anchor - 100_800L
            while (ts < anchor + 100_800L) {
                val viaFormatter = AnalyticsEngine.dayString(ts, off) == day
                val viaBounds = (ts + off) >= start && (ts + off) < start + 86_400L
                assertEquals("ts=$ts off=$off", viaFormatter, viaBounds)
                ts += 97L
            }
        }
    }

    @Test fun exactMidnightEdgesAtFractionalOffset() {
        // The two boundary seconds are where an off-by-one would hide: the local-midnight second is IN the
        // day, the next local-midnight second is OUT. +5:30 so a whole-hour bug can't pass by luck.
        val off = 5 * 3600L + 1800L
        val day = "2021-06-15"
        val start = AnalyticsEngine.dayStartUtcSeconds(day)   // 2021-06-15T00:00:00Z = 1623715200
        assertEquals(1_623_715_200L, start)
        val localMidnightUtcTs = start - off                  // wall-clock 00:00 +05:30 as a UTC instant
        val probes = listOf(
            localMidnightUtcTs to true,            // first second of the local day
            localMidnightUtcTs - 1 to false,       // last second of the day before
            localMidnightUtcTs + 86_399 to true,   // last second of the local day
            localMidnightUtcTs + 86_400 to false,  // first second of the next
        )
        for ((probe, expected) in probes) {
            assertEquals("probe=$probe", expected, AnalyticsEngine.dayString(probe, off) == day)
            assertEquals("probe=$probe", expected, (probe + off) >= start && (probe + off) < start + 86_400L)
        }
    }

    // --- dayStartUtcSeconds ----------------------------------------------------

    @Test fun dayStartUtcSecondsIsUtcMidnight() {
        assertEquals(0L, AnalyticsEngine.dayStartUtcSeconds("1970-01-01"))
        // 1_700_000_000 is 2023-11-14T22:13:20Z, so that day's UTC midnight is 80_000 s earlier.
        assertEquals(1_699_920_000L, AnalyticsEngine.dayStartUtcSeconds("2023-11-14"))
        assertEquals(1_623_715_200L, AnalyticsEngine.dayStartUtcSeconds("2021-06-15"))
    }

    @Test fun dayStartUtcSecondsRoundTripsThroughDayString() {
        for (day in listOf("1970-01-01", "2021-06-15", "2023-11-14", "2024-02-29", "2026-12-31")) {
            assertEquals(day, AnalyticsEngine.dayString(AnalyticsEngine.dayStartUtcSeconds(day)))
        }
    }

    @Test fun malformedDayFallsBackToEmptyEpochWindowNotATrap() {
        // Nil-tolerant failure mode (#996 review): a malformed `day` degrades to 0 — an empty 1970 window no
        // real sample matches — on BOTH platforms, never a crash. Unreachable in practice (`day` always comes
        // from dayString), locked so the parity can't silently drift.
        assertEquals(0L, AnalyticsEngine.dayStartUtcSeconds("not-a-day"))
        assertEquals(0L, AnalyticsEngine.dayStartUtcSeconds(""))
    }

    // --- Byte-identity pin: same inputs → same DailyMetric numbers -------------

    /** The optimization's whole contract: analyzeDay over FULL streams (which the tsInDay bounds check must
     *  trim to the day) produces the IDENTICAL DailyMetric as analyzeDay over streams PRE-trimmed with the old
     *  formatter compare. Runs at a fractional offset with spill samples planted on both sides of the local
     *  day, so any membership divergence changes the step/kcal/Effort numbers and fails equals. */
    @Test fun analyzeDayByteIdenticalToFormatterPrefilteredStreams() {
        for (off in listOf(5 * 3600L + 1800L, -(9 * 3600L + 1800L))) {   // +5:30 and −9:30
            val day = "2021-06-15"
            val localMid = AnalyticsEngine.dayStartUtcSeconds(day) - off
            // Full calendar-day HR every 10 s with ±2 h spill into the neighbour days; varying bpm so a
            // wrongly-included/excluded sample shifts the calorie/Effort sums, not just the count.
            val dayHr = (localMid - 7_200 until localMid + 86_400 + 7_200 step 10).map { ts ->
                HrSample(deviceId = "t", ts = ts, bpm = (60 + (ts / 10) % 40).toInt())
            }
            // Cumulative @57 counter every minute (+7/min) with the same spill; the spill deltas must be
            // excluded from the day total by BOTH filters identically.
            var counter = 100
            val daySteps = (localMid - 7_200 until localMid + 86_400 + 7_200 step 60).map { ts ->
                counter += 7
                StepSample(deviceId = "t", ts = ts, counter = counter and 0xFFFF)
            }
            val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")

            val full = AnalyticsEngine.analyzeDay(day = day, dayHr = dayHr, daySteps = daySteps,
                                                  profile = profile, tzOffsetSeconds = off)
            // The OLD path, byte for byte: pre-trim each stream with the formatter compare.
            val preHr = dayHr.filter { AnalyticsEngine.dayString(it.ts, off) == day }
            val preSteps = daySteps.filter { AnalyticsEngine.dayString(it.ts, off) == day }
            assertTrue("fixture must actually spill outside the day", preHr.size < dayHr.size)
            val pre = AnalyticsEngine.analyzeDay(day = day, dayHr = preHr, daySteps = preSteps,
                                                 profile = profile, tzOffsetSeconds = off)

            assertEquals("off=$off", pre.daily, full.daily)
            assertNotNull(full.daily.steps)          // the pin is vacuous if the day computed nothing
            assertNotNull(full.daily.activeKcalEst)
        }
    }
}
