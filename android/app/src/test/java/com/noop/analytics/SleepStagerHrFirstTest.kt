package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * HR-first sleep detection (experimental, default OFF): weight HR over motion when the two
 * disagree, and assemble one session per sleep period across short wake gaps.
 *
 * Per the "validate against varying inputs" rule (#194/#345), these tests inject the sleep window
 * at DIFFERENT positions and lengths and assert the rescue TRACKS it — and that the identical
 * motion pattern with an elevated (awake) HR is refused — rather than pinning one matched night.
 * Faithful Kotlin mirror of SleepStagerHrFirstTests.swift: same scenarios, same numbers.
 */
class SleepStagerHrFirstTest {

    private val dev = "test"

    /** 2026-06-10 00:00:00 UTC — same fixed midnight the Swift twin uses. */
    private val refMidnight = 1_749_513_600L

    private fun at(hourUTC: Int, min: Int = 0): Long = refMidnight + hourUTC * 3_600L + min * 60L

    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    /** Oscillating orientation (0.5 g jumps per sample) — clearly "moving" to the stillness spine. */
    private fun restlessGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { i ->
            val phase = (i % 2) * 0.5
            GravitySample(deviceId = dev, ts = start + i, x = phase, y = 0.0, z = 1.0)
        }

    private fun hrStream(start: Long, durationS: Int, bpm: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    // ── Restless-night rescue (the DROPPED-night failure) ─────────────────────

    @Test
    fun restlessNightRescuedToFullSession() {
        // Restless (motion "active") but cardiac-unambiguous (HR 52 vs awake 75) 22:00–04:30,
        // then still to 06:00. OFF: only the quiescent morning fragment scores. ON: one session.
        val grav = restlessGravity(at(22), 6 * 3_600 + 1_800) +          // 22:00–04:30
            stillGravity(at(28, 30), 90 * 60)                            // 04:30–06:00
        val hr = hrStream(at(20), 2 * 3_600, 75) +                       // 20:00–22:00 awake
            hrStream(at(22), 8 * 3_600, 52) +                            // 22:00–06:00 asleep
            hrStream(at(30), 2 * 3_600, 75)                              // 06:00–08:00 awake

        val off = SleepStager.detectSleep(hr = hr, gravity = grav)
        assertEquals("OFF: only the still morning fragment should score", 1, off.size)
        assertTrue("OFF fragment starts near 04:30", off[0].start >= at(28, 25))
        assertTrue(off[0].start <= at(28, 45))

        val on = SleepStager.detectSleep(hr = hr, gravity = grav, hrFirstSleep = true)
        assertEquals("ON: one assembled session for the whole night", 1, on.size)
        assertTrue("ON: onset tracks the injected 22:00 sleep start", on[0].start <= at(22) + 120)
        assertTrue("ON: end tracks the injected 06:00 wake", on[0].end >= at(30) - 120)
    }

    @Test
    fun restlessRescueTracksInjectedWindow() {
        // Same rescue with the sleep window injected at a DIFFERENT position and length
        // (01:00–07:30, all restless, no still stretch at all).
        val grav = restlessGravity(at(25), 6 * 3_600 + 1_800)            // 01:00–07:30
        val hr = hrStream(at(22), 3 * 3_600, 75) +                       // 22:00–01:00 awake
            hrStream(at(25), 6 * 3_600 + 1_800, 52) +                    // 01:00–07:30 asleep
            hrStream(at(31, 30), 2 * 3_600, 75)                          // 07:30–09:30 awake

        assertEquals("OFF: an all-restless night scores nothing",
            0, SleepStager.detectSleep(hr = hr, gravity = grav).size)

        val on = SleepStager.detectSleep(hr = hr, gravity = grav, hrFirstSleep = true)
        assertEquals(1, on.size)
        assertTrue("onset tracks the moved window", abs(on[0].start - at(25)) <= 120)
        assertTrue("end tracks the moved window", abs(on[0].end - at(31, 30)) <= 120)
    }

    @Test
    fun elevatedHrNightIsNotRescued() {
        // IDENTICAL motion to the full-night rescue, night HR elevated (78 vs a 62 day median):
        // the rescue must refuse the restless stretch. (The STILL morning fragment is still
        // accepted by the pre-existing motion-corroborated quiescent band (#462), so the assertion
        // is that HR-first adds NOTHING: same single fragment, onset still at the quiescent stretch.)
        val grav = restlessGravity(at(22), 6 * 3_600 + 1_800) +          // 22:00–04:30
            stillGravity(at(28, 30), 90 * 60)                            // 04:30–06:00
        val hr = hrStream(at(22), 8 * 3_600, 78) +                       // 22:00–06:00 elevated
            hrStream(at(30), 10 * 3_600, 62)                             // 06:00–16:00 day median

        val off = SleepStager.detectSleep(hr = hr, gravity = grav)
        val on = SleepStager.detectSleep(hr = hr, gravity = grav, hrFirstSleep = true)
        assertEquals("same motion, elevated HR: HR-first must change nothing", off, on)
        assertEquals(1, on.size)
        assertTrue("the restless 22:00–04:30 stretch must NOT be rescued", on[0].start >= at(28, 25))
    }

    // ── Wake-gap bridging (the SPLIT-night failure) ──────────────────────────

    @Test
    fun briefGetUpBridgedIntoOneSession() {
        // A 16-min get-up (real movement + HR 80) mid-night. The centered rolling window smears it
        // past mergeMin, so OFF stores TWO sessions; ON bridges them into ONE.
        val grav = stillGravity(at(23), 4 * 3_600) +                     // 23:00–03:00
            restlessGravity(at(27), 16 * 60) +                           // 03:00–03:16 get-up
            stillGravity(at(27, 16), 3 * 3_600 + 44 * 60)                // 03:16–07:00
        val hr = hrStream(at(21), 2 * 3_600, 75) +
            hrStream(at(23), 4 * 3_600, 52) +
            hrStream(at(27), 16 * 60, 80) +
            hrStream(at(27, 16), 3 * 3_600 + 44 * 60, 52) +
            hrStream(at(31), 2 * 3_600, 75)

        assertEquals("OFF: the smeared get-up splits the night",
            2, SleepStager.detectSleep(hr = hr, gravity = grav).size)

        val on = SleepStager.detectSleep(hr = hr, gravity = grav, hrFirstSleep = true)
        assertEquals("ON: one session bridging the get-up", 1, on.size)
        assertTrue(abs(on[0].start - at(23)) <= 120)
        assertTrue(abs(on[0].end - at(31)) <= 120)
    }

    @Test
    fun longWakeGapStaysSplit() {
        // An 80-min genuinely-awake block (elevated HR, real movement) exceeds the 45-min bridge.
        val grav = stillGravity(at(22), 3 * 3_600) +                     // 22:00–01:00
            restlessGravity(at(25), 80 * 60) +                           // 01:00–02:20 awake
            stillGravity(at(26, 20), 3 * 3_600 + 40 * 60)                // 02:20–06:00
        val hr = hrStream(at(20), 2 * 3_600, 75) +
            hrStream(at(22), 3 * 3_600, 52) +
            hrStream(at(25), 80 * 60, 78) +
            hrStream(at(26, 20), 3 * 3_600 + 40 * 60, 52) +
            hrStream(at(30), 2 * 3_600, 75)

        assertEquals("an over-threshold wake gap must not be bridged",
            2, SleepStager.detectSleep(hr = hr, gravity = grav, hrFirstSleep = true).size)
    }

    // ── Guards still hold on assembled runs ──────────────────────────────────

    @Test
    fun daytimeGuardStillAppliesToRescuedRuns() {
        // A rescued + bridged DAYTIME stretch (in-band flat HR 60, no cardiac dip) must still be
        // dropped by the daytime false-sleep guard.
        val grav = stillGravity(at(11), 2 * 3_600) +                     // 11:00–13:00
            restlessGravity(at(13), 2 * 3_600) +                         // 13:00–15:00
            stillGravity(at(15), 2 * 3_600)                              // 15:00–17:00
        val hr = hrStream(at(10), 8 * 3_600, 60)                         // flat, no dip

        assertEquals("no resting-HR dip: the daytime guard must reject the rescue",
            0, SleepStager.detectSleep(hr = hr, gravity = grav, hrFirstSleep = true).size)
    }

    @Test
    fun defaultOffIsByteIdentical() {
        val grav = stillGravity(at(23), 4 * 3_600) +
            restlessGravity(at(27), 16 * 60) +
            stillGravity(at(27, 16), 3 * 3_600 + 44 * 60)
        val hr = hrStream(at(23), 8 * 3_600, 52) + hrStream(at(31), 4 * 3_600, 75)

        val implicitDefault = SleepStager.detectSleep(hr = hr, gravity = grav)
        val explicitFalse = SleepStager.detectSleep(hr = hr, gravity = grav, hrFirstSleep = false)
        assertEquals(implicitDefault, explicitFalse)
    }

    // ── Pure helpers ─────────────────────────────────────────────────────────

    @Test
    fun bridgeWakeGapsMergesOnlyUnderThreshold() {
        val a = SleepStager.Period(stage = "sleep", start = 0L, end = 3_600L)
        val gap = SleepStager.Period(stage = "active", start = 3_600L, end = 3_600L + 40 * 60)
        val b = SleepStager.Period(stage = "sleep", start = 3_600L + 40 * 60, end = 3 * 3_600L)
        val merged = SleepStager.bridgeWakeGaps(listOf(a, gap, b))
        assertEquals(1, merged.size)
        assertEquals(0L, merged[0].start)
        assertEquals(3 * 3_600L, merged[0].end)

        val farGap = SleepStager.Period(stage = "active", start = 3_600L, end = 3_600L + 46 * 60)
        val c = SleepStager.Period(stage = "sleep", start = 3_600L + 46 * 60, end = 4 * 3_600L)
        assertEquals("a 46-min gap is over wakeBridgeMaxMin (45) and must not merge",
            3, SleepStager.bridgeWakeGaps(listOf(a, farGap, c)).size)
    }

    @Test
    fun hrRescueRespectsBandAndSampleFloor() {
        val p = SleepStager.Period(stage = "active", start = 0L, end = 3_600L)
        val inBand = (0 until 3_600).map { HrSample(deviceId = dev, ts = it.toLong(), bpm = 52) }
        assertEquals("sleep", SleepStager.hrRescueActiveRuns(listOf(p), inBand, 52.0)[0].stage)

        val outOfBand = (0 until 3_600).map { HrSample(deviceId = dev, ts = it.toLong(), bpm = 60) }
        assertEquals("median above baseline × 1.05 must not rescue",
            "active", SleepStager.hrRescueActiveRuns(listOf(p), outOfBand, 52.0)[0].stage)

        // Below the hrRefineMinSamples floor: too little cardiac evidence to overrule motion.
        val sparse = (0 until 10).map { HrSample(deviceId = dev, ts = it * 60L, bpm = 52) }
        assertEquals("active", SleepStager.hrRescueActiveRuns(listOf(p), sparse, 52.0)[0].stage)

        // No baseline at all: nothing to weigh HR against.
        assertEquals("active", SleepStager.hrRescueActiveRuns(listOf(p), inBand, null)[0].stage)
    }
}
