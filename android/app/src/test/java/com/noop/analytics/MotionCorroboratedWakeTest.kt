package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.roundToInt

/**
 * Motion-corroborated wake (elevated-but-flat-HR nights, #462). Android twin of the Swift
 * `MotionCorroboratedWakeTests`. Both stagers and the HR-led session confirmation call "wake" primarily off
 * HR / HR-variability; on a night whose resting HR is held elevated WITHOUT the wearer getting up (a
 * supplement protocol, a fever, a hot room, alcohol) that logic misreads hot-but-motionless sleep as wake.
 * These fixtures replicate the two confirmed mis-scored nights and pin the rule: elevated-HR ALONE cannot
 * call wake when the wrist is at the night's quiescent motion floor with unchanged posture, while genuine
 * out-of-bed motion still breaks sleep.
 */
class MotionCorroboratedWakeTest {

    private val dev = "test"

    // ── fixtures ───────────────────────────────────────────────────────────────────────────────────────

    /** A perfectly still gravity stream (fixed orientation) at 1 Hz — the quiescent sleep floor. */
    private fun stillGravity(start: Long, durationS: Int, x: Double = 0.0, y: Double = 0.0, z: Double = 1.0):
        List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = x, y = y, z = z) }

    /** Still gravity with brief single-minute TURN-OVER bursts every [everyMin] minutes (a posture flip that
     *  lasts a few seconds) — a sleeping body, not an awakening. Between bursts posture is fixed. */
    private fun stillWithTurnovers(start: Long, durationS: Int, everyMin: Int): List<GravitySample> =
        (0 until durationS).map { i ->
            val minute = i / 60
            val isBurstMinute = minute % everyMin == 0 && minute > 0
            val inBurst = isBurstMinute && (i % 60) < 4   // ~4 s of turn-over inside the burst minute
            if (inBurst) GravitySample(deviceId = dev, ts = start + i, x = 0.35, y = 0.30, z = 0.87)
            else GravitySample(deviceId = dev, ts = start + i, x = 0.0, y = 0.0, z = 1.0)
        }

    /** A sustained WALKING gravity stream — every second a different orientation with a large step-cadence
     *  jerk (out of bed, pacing). Breaks sleep at both the detection and stage level. */
    private fun walkingGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { i ->
            val ph = (i % 4).toDouble()
            GravitySample(deviceId = dev, ts = start + i, x = 0.5 * sin(ph), y = 0.5 * cos(ph), z = 0.7)
        }

    /** Elevated-but-FLAT HR at 1 Hz (supplement era: resting HR held ~[base], natural would be ~48). */
    private fun elevatedFlatHR(start: Long, durationS: Int, base: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = base + (it / 90) % 3) }

    /** A regular R-R stream (~[meanMs] ms beats with a small respiratory oscillation). */
    private fun regularRR(start: Long, durationS: Int, meanMs: Int = 1000): List<RrInterval> =
        (0 until durationS).map { i ->
            val rsa = (40.0 * sin(2.0 * PI * i / 4.0)).roundToInt()
            RrInterval(deviceId = dev, ts = start + i, rrMs = meanMs + rsa)
        }

    private fun wakeMinutes(segs: List<StageSegment>): Double =
        segs.filter { it.stage == "wake" }.sumOf { (it.end - it.start).toDouble() } / 60.0

    // ── V2 stage level: the primary default-path fix ─────────────────────────────────────────────────────

    /** The 7/13 pattern: a ~6 h warm-flat-HR still night (turn-over bursts on a ~90-min rhythm, no walking)
     *  must NOT be carpeted in WAKE. */
    @Test
    fun warmFlatHRStillNightScoresAsleepNotWakeV2() {
        val start = 1_749_517_200L
        val dur = 6 * 60 * 60
        val segs = SleepStagerV2.stageSession(
            start = start, end = start + dur,
            grav = stillWithTurnovers(start, dur, everyMin = 90),
            hr = elevatedFlatHR(start, dur, base = 58),
            rr = regularRR(start, dur, meanMs = 1030),
            resp = emptyList())
        assertTrue(
            "a warm-but-still night must score mostly asleep, not WAKE (got ${wakeMinutes(segs)} min)",
            wakeMinutes(segs) < 60.0,
        )
    }

    /** The still low-HR baseline case must be byte-identical to before the fix (the change only ever removes
     *  wake-PROMOTING cardiac evidence on quiescent epochs; a low, flat HR contributes none). */
    @Test
    fun stillLowHRNightUnchangedByCorrectionV2() {
        val start = 1_749_517_200L
        val dur = 3 * 60 * 60
        val segs = SleepStagerV2.stageSession(
            start = start, end = start + dur,
            grav = stillGravity(start, dur),
            hr = elevatedFlatHR(start, dur, base = 48),   // natural resting
            rr = regularRR(start, dur),
            resp = emptyList())
        assertTrue("a still low-HR night should be essentially all sleep", wakeMinutes(segs) < 15.0)
    }

    /** Genuine out-of-bed WALKING within an otherwise-still night must still be scored WAKE by V2 — the
     *  correction must not swallow a real awakening. */
    @Test
    fun walkingGapWithinStillNightScoresWakeV2() {
        val start = 1_749_517_200L
        val dur = 5 * 60 * 60
        val walkStart = 2 * 60 * 60          // a 30-min out-of-bed block two hours in
        val walkEnd = walkStart + 30 * 60
        val grav = (0 until dur).map { i ->
            if (i in walkStart until walkEnd) {
                val ph = (i % 4).toDouble()
                GravitySample(deviceId = dev, ts = start + i, x = 0.5 * sin(ph), y = 0.5 * cos(ph), z = 0.7)
            } else {
                GravitySample(deviceId = dev, ts = start + i, x = 0.0, y = 0.0, z = 1.0)
            }
        }
        // Elevated during the walk (out of bed), flat-elevated otherwise (supplement).
        val hr = (0 until dur).map { i ->
            HrSample(deviceId = dev, ts = start + i, bpm = if (i in walkStart until walkEnd) 92 else 58)
        }
        val segs = SleepStagerV2.stageSession(
            start = start, end = start + dur, grav = grav,
            hr = hr, rr = regularRR(start, dur, meanMs = 1030), resp = emptyList())
        val walkWake = segs.filter {
            it.stage == "wake" && it.end > start + walkStart && it.start < start + walkEnd
        }.sumOf {
            (minOf(it.end, start + walkEnd) - maxOf(it.start, start + walkStart)).toDouble()
        } / 60.0
        assertTrue("the walking block must remain WAKE (got $walkWake min of 30)", walkWake > 15.0)
        assertTrue(
            "the still remainder must not be scored WAKE despite elevated HR",
            wakeMinutes(segs) < 60.0,
        )
    }

    // ── the motion-quiescent predicate ───────────────────────────────────────────────────────────────────

    @Test
    fun motionQuiescentPredicate() {
        val still = SleepStagerV2.Epoch(
            start = 0, hr = 58.0, hrVar = 1.0, hrFlat11 = 1.0, moveFrac = 0.0, jerkMax = 0.001,
            respReg = null, clock = 0.5, jerkScale = 0.001, minutesSinceOnset = 120.0)
        assertTrue(SleepStagerV2.motionQuiescent(still))
        val moved = SleepStagerV2.Epoch(
            start = 0, hr = 58.0, hrVar = 1.0, hrFlat11 = 1.0, moveFrac = 0.3, jerkMax = 0.2,
            respReg = null, clock = 0.5, jerkScale = 0.001, minutesSinceOnset = 120.0)
        assertFalse(SleepStagerV2.motionQuiescent(moved))
    }

    // ── detection level: confirmSleepWithHR motion corroboration ─────────────────────────────────────────

    private fun period(start: Long, durS: Int) =
        SleepStager.Period(stage = "sleep", start = start, end = start + durS)

    /** A supplement night whose whole in-bed run is motionless but HR-elevated (median ~58 vs baseline 48,
     *  above the strict ×1.05 = 50.4 bar) must NOT be rejected by the HR gate when gravity proves the wrist
     *  was still — the widened quiescent band keeps it. Without gravity evidence the strict bar stands. */
    @Test
    fun motionlessElevatedRunConfirmedWithGravity() {
        val start = 1_000_000L
        val dur = 90 * 60
        val p = period(start, dur)
        val hr = elevatedFlatHR(start, dur, base = 58)
        val stillGrav = stillGravity(start, dur)
        assertTrue(
            "a motionless but HR-elevated run must be confirmed as sleep when stillness is proven",
            SleepStager.confirmSleepWithHR(p, hr, baseline = 48.0, grav = stillGrav),
        )
        assertFalse(
            "with no motion evidence the strict HR band still rejects an elevated run",
            SleepStager.confirmSleepWithHR(p, hr, baseline = 48.0),
        )
    }

    /** The floor holds: a genuinely awake, motionless run whose median HR is far above the band (72 vs
     *  baseline 48 → above even the widened ×1.30 = 62.4 bar) is STILL rejected even with stillness proven. */
    @Test
    fun genuinelyHighHRStillRunStillRejected() {
        val start = 1_000_000L
        val dur = 90 * 60
        val p = period(start, dur)
        val hr = elevatedFlatHR(start, dur, base = 72)
        val stillGrav = stillGravity(start, dur)
        assertFalse(
            "a run whose HR is above even the widened quiescent band must still be rejected",
            SleepStager.confirmSleepWithHR(p, hr, baseline = 48.0, grav = stillGrav),
        )
    }

    @Test
    fun runIsDeeplyQuiescent() {
        val start = 1_000_000L
        val dur = 60 * 60
        val p = period(start, dur)
        assertTrue(SleepStager.runIsDeeplyQuiescent(p, stillGravity(start, dur)))
        assertTrue(
            "occasional turn-overs still leave >90% of minutes posture-stable",
            SleepStager.runIsDeeplyQuiescent(p, stillWithTurnovers(start, dur, everyMin = 90)),
        )
        assertFalse(
            "a walking run is not posture-stable",
            SleepStager.runIsDeeplyQuiescent(p, walkingGravity(start, dur)),
        )
        assertFalse(
            "no gravity → stillness unprovable → not deeply quiescent",
            SleepStager.runIsDeeplyQuiescent(p, emptyList()),
        )
    }

    // ── adaptive overnight HR baseline (directive b) ─────────────────────────────────────────────────────

    @Test
    fun adaptiveOvernightHRBaseline() {
        // Self-calibrates to recent overnight medians (a supplement era's ~58 vs a fixed day-median).
        val era = SleepStager.adaptiveOvernightHRBaseline(listOf(56.0, 58.0, 60.0, 57.0, 59.0))
        assertNotNull(era)
        assertEquals(58.0, era!!, 1e-9)
        // Floor holds so a wakeful era can't collapse the band.
        val floored = SleepStager.adaptiveOvernightHRBaseline(listOf(30.0, 32.0, 31.0))
        assertNotNull(floored)
        assertEquals(SleepStager.adaptiveBaselineFloor, floored!!, 1e-9)
        // No history → null (caller keeps the day-median).
        assertEquals(null, SleepStager.adaptiveOvernightHRBaseline(emptyList()))
    }
}
