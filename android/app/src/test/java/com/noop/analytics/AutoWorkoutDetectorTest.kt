package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parity tests for the MVP [AutoWorkoutDetector] — mirrors
 * StrandAnalytics/AutoWorkoutDetectorTests.swift case-for-case so the two platforms stay
 * byte-parity on the detection logic.
 *
 * Cases: elevated span detected; brief dip tolerated; short/low spans rejected; near windows
 * merged; window overlapping a saved workout excluded.
 */
class AutoWorkoutDetectorTest {

    private val dev = "test-device"
    private fun hr(ts: Long, bpm: Int) = HrSample(deviceId = dev, ts = ts, bpm = bpm)
    private fun grav(ts: Long, x: Double) =
        GravitySample(deviceId = dev, ts = ts, x = x, y = 0.0, z = 1.0)

    /** Build a flat 1 Hz HR block [start, start+durS) at [bpm]. */
    private fun block(start: Long, durS: Int, bpm: Int): List<HrSample> =
        (0 until durS).map { hr(start + it, bpm) }

    // resting 60 → floor = 90. Workout bpm 120 is elevated; rest bpm 65 is not.

    @Test fun elevatedSpanIsDetected() {
        // 20 min sustained at 120 bpm, embedded in rest. One workout, ~20 min, avg/peak 120.
        val rest = 60
        val start = 1_000_000L
        val durS = 20 * 60
        val hr = block(start - 600, 600, 65) + block(start, durS, 120) + block(start + durS, 600, 65)
        val out = AutoWorkoutDetector.detect(hr, restingHR = rest)
        assertEquals(1, out.size)
        val w = out[0]
        assertEquals(120, w.avgBpm)
        assertEquals(120, w.peakBpm)
        assertTrue("duration ${w.durationMin} min", w.durationMin >= 19)
        assertEquals(start, w.startSec)
    }

    @Test fun briefDipIsTolerated() {
        // 10 min at 120, a 60 s dip to 70 (below floor, but <= 90 s), then 10 min at 120.
        // The dip must NOT split the span → one ~21 min workout.
        val rest = 60
        val start = 2_000_000L
        val first = block(start, 600, 120)
        val dip = block(start + 600, 60, 70)
        val second = block(start + 660, 600, 120)
        val hr = block(start - 300, 300, 65) + first + dip + second + block(start + 1260, 300, 65)
        val out = AutoWorkoutDetector.detect(hr, restingHR = rest)
        assertEquals("dip split the span into ${out.size}", 1, out.size)
        assertTrue("merged span too short: ${out[0].durationMin} min", out[0].durationMin >= 20)
    }

    @Test fun shortSpanIsRejected() {
        // 8 min at 120 (< 12 min minimum) → nothing.
        val rest = 60
        val start = 3_000_000L
        val hr = block(start - 300, 300, 65) + block(start, 8 * 60, 120) + block(start + 480, 300, 65)
        assertTrue(AutoWorkoutDetector.detect(hr, restingHR = rest).isEmpty())
    }

    @Test fun lowSpanIsRejected() {
        // 20 min at 85 bpm: resting 60 → floor 90, so 85 never clears the gate → nothing.
        val rest = 60
        val start = 4_000_000L
        val hr = block(start - 300, 300, 65) + block(start, 20 * 60, 85) + block(start + 1200, 300, 65)
        assertTrue(AutoWorkoutDetector.detect(hr, restingHR = rest).isEmpty())
    }

    @Test fun nearWindowsAreMerged() {
        // Two 15 min bouts at 120 separated by a 3 min true rest at 65 (< 5 min merge gap, but the rest
        // is > 90 s so it CLOSES each span). The two closed spans are then MERGED into one (gap < 5 min).
        val rest = 60
        val start = 5_000_000L
        val a = block(start, 15 * 60, 120)
        val gap = block(start + 900, 3 * 60, 65) // 180 s rest > maxDipS → span closes
        val b = block(start + 1080, 15 * 60, 120)
        val hr = block(start - 300, 300, 65) + a + gap + b + block(start + 1980, 300, 65)
        val out = AutoWorkoutDetector.detect(hr, restingHR = rest)
        assertEquals("near windows not merged: ${out.size}", 1, out.size)
        // Merged span runs from the first bout's start to the second bout's end (~33 min).
        assertTrue("merged span too short: ${out[0].durationMin} min", out[0].durationMin >= 30)
    }

    @Test fun farWindowsStaySeparate() {
        // Two 15 min bouts at 120 separated by a 10 min rest (>= 5 min merge gap) → two workouts.
        val rest = 60
        val start = 6_000_000L
        val a = block(start, 15 * 60, 120)
        val gap = block(start + 900, 10 * 60, 65)
        val b = block(start + 1500, 15 * 60, 120)
        val hr = block(start - 300, 300, 65) + a + gap + b + block(start + 2400, 300, 65)
        val out = AutoWorkoutDetector.detect(hr, restingHR = rest)
        assertEquals(2, out.size)
    }

    @Test fun windowOverlappingSavedWorkoutIsExcluded() {
        // A clean 20 min bout, but a saved workout already covers the middle of it → suggestion suppressed.
        val rest = 60
        val start = 7_000_000L
        val hr = block(start - 300, 300, 65) + block(start, 20 * 60, 120) + block(start + 1200, 300, 65)
        val saved = listOf((start + 300) to (start + 600)) // overlaps the detected span
        assertTrue(AutoWorkoutDetector.detect(hr, restingHR = rest, savedWorkouts = saved).isEmpty())
        // Sanity: with the overlap removed, it IS detected.
        assertEquals(1, AutoWorkoutDetector.detect(hr, restingHR = rest).size)
    }

    @Test fun motionConfirmationGatesWhenSeriesPresent() {
        // Same elevated HR bout, but the gravity series is perfectly STILL over the window → no motion
        // confirmation → rejected. With no gravity series (HR-only) the same bout IS detected.
        val rest = 60
        val start = 8_000_000L
        val hr = block(start - 300, 300, 65) + block(start, 20 * 60, 120) + block(start + 1200, 300, 65)
        val still = (start until start + 1200).map { grav(it, 0.0) } // zero motion delta
        assertTrue(AutoWorkoutDetector.detect(hr, restingHR = rest, gravity = still).isEmpty())
        assertEquals(1, AutoWorkoutDetector.detect(hr, restingHR = rest).size)
        // Moving gravity (alternating x) confirms motion → detected.
        val moving = (start until start + 1200).map { grav(it, ((it - start) % 2).toDouble() * 0.5) }
        assertEquals(1, AutoWorkoutDetector.detect(hr, restingHR = rest, gravity = moving).size)
    }

    @Test fun emptyInputIsEmpty() {
        assertTrue(AutoWorkoutDetector.detect(emptyList()).isEmpty())
    }

    @Test fun defaultRestingHrIsUsedWhenNull() {
        // No restingHR → default 60 → floor 90. 20 min at 120 is detected.
        val start = 9_000_000L
        val hr = block(start - 300, 300, 65) + block(start, 20 * 60, 120) + block(start + 1200, 300, 65)
        assertEquals(1, AutoWorkoutDetector.detect(hr).size)
    }

    @Test fun configurableQualificationHasExactTenMinuteBoundary() {
        val start = 10_000_000L
        val nineMinutesFiftyNine = block(start, 10 * 60, 120) // inclusive span is 599 s
        val exactlyTenMinutes = block(start, 10 * 60 + 1, 120) // inclusive span is 600 s

        assertTrue(
            AutoWorkoutDetector.detect(
                nineMinutesFiftyNine, restingHR = 60, minimumSustainedMinutes = 10.0,
            ).isEmpty(),
        )
        assertEquals(
            1,
            AutoWorkoutDetector.detect(
                exactlyTenMinutes, restingHR = 60, minimumSustainedMinutes = 10.0,
            ).size,
        )
    }

    @Test fun configurableQualificationHasExactFifteenMinuteBoundary() {
        val start = 11_000_000L
        val fourteenMinutesFiftyNine = block(start, 15 * 60, 120) // inclusive span is 899 s
        val exactlyFifteenMinutes = block(start, 15 * 60 + 1, 120) // inclusive span is 900 s

        assertTrue(
            AutoWorkoutDetector.detect(
                fourteenMinutesFiftyNine, restingHR = 60, minimumSustainedMinutes = 15.0,
            ).isEmpty(),
        )
        assertEquals(
            1,
            AutoWorkoutDetector.detect(
                exactlyFifteenMinutes, restingHR = 60, minimumSustainedMinutes = 15.0,
            ).size,
        )
    }

    @Test fun publishedDefaultRemainsTwelveMinutes() {
        val start = 12_000_000L
        val elevenMinutesFiftyNine = block(start, 12 * 60, 120)
        val exactlyTwelveMinutes = block(start, 12 * 60 + 1, 120)

        assertEquals(listOf(10.0, 15.0), AutoWorkoutDetector.shadowSustainedMinutes)
        assertTrue(AutoWorkoutDetector.detect(elevenMinutesFiftyNine, restingHR = 60).isEmpty())
        assertEquals(1, AutoWorkoutDetector.detect(exactlyTwelveMinutes, restingHR = 60).size)
    }
}
