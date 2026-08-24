package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Wake-gap bridging (experimental, default OFF): assemble adjacent sleep runs across ≤ 45-min wake
 * gaps into ONE candidate run, so a brief get-up stays inside one session as staged wake.
 *
 * Includes a REAL-DATA pin: the exact seam layout of a reporting wearer's stored fragmented nights
 * (Aug 2026 mirror), asserting precisely which seams the bridge merges and which it leaves split.
 * An HR-led rescue of restless-but-asleep nights was prototyped alongside this bridge and WITHDRAWN
 * after a real-data replay — see the Swift history note above `SleepStager.wakeBridgeMaxMin`; the
 * restless-night test below pins that the bridge deliberately does NOT fix that failure.
 * Faithful Kotlin mirror of SleepStagerWakeBridgeTests.swift: same scenarios, same numbers.
 */
class SleepStagerWakeBridgeTest {

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

        val on = SleepStager.detectSleep(hr = hr, gravity = grav, wakeBridge = true)
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
            2, SleepStager.detectSleep(hr = hr, gravity = grav, wakeBridge = true).size)
    }

    @Test
    fun restlessNightIsNotRescuedByBridge() {
        // The withdrawn-rescue pin: a restless night (motion "active", HR at clear sleep levels) is
        // NOT rescued by the bridge — ON must change nothing versus OFF. The bridge only assembles
        // runs the unchanged stillness spine already accepted.
        val grav = restlessGravity(at(22), 6 * 3_600 + 1_800) +          // 22:00–04:30
            stillGravity(at(28, 30), 90 * 60)                            // 04:30–06:00
        val hr = hrStream(at(20), 2 * 3_600, 75) +
            hrStream(at(22), 8 * 3_600, 52) +
            hrStream(at(30), 2 * 3_600, 75)

        val off = SleepStager.detectSleep(hr = hr, gravity = grav)
        val on = SleepStager.detectSleep(hr = hr, gravity = grav, wakeBridge = true)
        assertEquals("the bridge must not reclassify restless stretches", off, on)
        assertEquals("only the still morning fragment scores either way", 1, on.size)
        assertTrue(on[0].start >= at(28, 25))
    }

    // ── Guards still hold on assembled runs ──────────────────────────────────

    @Test
    fun daytimeGuardStillAppliesToBridgedRuns() {
        // Two still DAYTIME stretches bridged across a 30-min gap (flat in-band HR, no cardiac dip)
        // must still be dropped by the daytime false-sleep guard on the ASSEMBLED window.
        val grav = stillGravity(at(12), 2 * 3_600) +                     // 12:00–14:00
            stillGravity(at(14, 30), 2 * 3_600)                          // 14:30–16:30
        val hr = hrStream(at(10), 8 * 3_600, 60)                         // flat, no dip

        assertEquals("no resting-HR dip: the daytime guard must reject the bridged window",
            0, SleepStager.detectSleep(hr = hr, gravity = grav, wakeBridge = true).size)
    }

    @Test
    fun defaultOffIsByteIdentical() {
        val grav = stillGravity(at(23), 4 * 3_600) +
            restlessGravity(at(27), 16 * 60) +
            stillGravity(at(27, 16), 3 * 3_600 + 44 * 60)
        val hr = hrStream(at(23), 8 * 3_600, 52) + hrStream(at(31), 4 * 3_600, 75)

        val implicitDefault = SleepStager.detectSleep(hr = hr, gravity = grav)
        val explicitFalse = SleepStager.detectSleep(hr = hr, gravity = grav, wakeBridge = false)
        assertEquals(implicitDefault, explicitFalse)
    }

    // ── Pure helper ──────────────────────────────────────────────────────────

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
    fun bridgeRefusesOverSpanCapMerge() {
        // H4 span guard: a merge whose ASSEMBLED span would exceed maxMainSleepSpanS (16 h) is
        // refused, so a pathological chain can never assemble and then be dropped whole by the
        // ladder's cap — the exact failure the withdrawn HR rescue exhibited on real data.
        val a = SleepStager.Period(stage = "sleep", start = 0L, end = 8 * 3_600L)
        val b = SleepStager.Period(stage = "sleep", start = 8 * 3_600L + 30 * 60, end = 17 * 3_600L)
        assertEquals("a merge assembling a >16 h span must be refused",
            2, SleepStager.bridgeWakeGaps(listOf(a, b)).size)
    }

    // ── Real-data seam pin (Aug 2026 mirror, reporting wearer's stored fragments) ──

    @Test
    fun realNightSeamsBridgeExactly() {
        // The stored fragment layouts of five REAL split nights, as (start, end) unix pairs from
        // the wearer's server mirror. Asserts exactly which seams the 45-min bridge merges
        // (16/12/28/25+19-min arousal seams) and which it leaves split (2.2–3.9 h genuine wake
        // gaps, and a 90-min morning re-sleep gap — over the threshold, left to the selector's
        // #861 night-tail bridge). Same pairs as the Swift twin.
        fun sleeps(spans: List<Pair<Long, Long>>): List<SleepStager.Period> =
            spans.map { SleepStager.Period(stage = "sleep", start = it.first, end = it.second) }

        // Aug 11→12 ET: 4 fragments; only the 16-min bathroom seam (06:17→06:33 ET) merges → 3 blocks.
        val aug12 = sleeps(listOf(1786491049L to 1786496628L, 1786510824L to 1786514588L,
            1786522512L to 1786529853L, 1786530794L to 1786541952L))
        assertEquals(listOf(1786491049L to 1786496628L, 1786510824L to 1786514588L,
            1786522512L to 1786541952L),
            SleepStager.bridgeWakeGaps(aug12).map { it.start to it.end })

        // Aug 17→18 ET: 3 fragments; the 12-min seam merges, the 3.8 h gap stays → 2 blocks.
        val aug18 = sleeps(listOf(1787032890L to 1787037056L, 1787050829L to 1787054649L,
            1787055394L to 1787063445L))
        assertEquals(listOf(1787032890L to 1787037056L, 1787050829L to 1787063445L),
            SleepStager.bridgeWakeGaps(aug18).map { it.start to it.end })

        // Aug 18→19 ET: 2 fragments at a 28-min seam → 1 block.
        val aug19 = sleeps(listOf(1787126248L to 1787132602L, 1787134284L to 1787141425L))
        assertEquals(listOf(1787126248L to 1787141425L),
            SleepStager.bridgeWakeGaps(aug19).map { it.start to it.end })

        // Aug 20→21 ET: 3 fragments at 25-min and 19-min seams → 1 block (11.4 h < the 16 h cap).
        // NOTE: the mirror's correction pass (an HR-evidence-led edit session, not a human label)
        // kept the third block (a post-wake morning doze) as a SEPARATE doze; the 45-min rule cannot
        // distinguish "brief wake, more sleep" from "woke, dozed again", so the bridge deliberately
        // folds it in (wake staged inside). Pinned as-is.
        val aug21 = sleeps(listOf(1787287220L to 1787297404L, 1787298936L to 1787322337L,
            1787323440L to 1787328166L))
        assertEquals(listOf(1787287220L to 1787328166L),
            SleepStager.bridgeWakeGaps(aug21).map { it.start to it.end })

        // Aug 23→24 ET: 2 fragments at a 90-min gap → stays split (over the 45-min bridge). The
        // mirror's correction pass filled this gap as SLEEP on HR evidence — it is the
        // withdrawn-rescue (restless dropping) class, not a seam; the bridge must not guess it.
        val aug24 = sleeps(listOf(1787546768L to 1787551261L, 1787556701L to 1787575851L))
        assertEquals(2, SleepStager.bridgeWakeGaps(aug24).size)
    }
}
