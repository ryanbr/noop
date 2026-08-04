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
import kotlin.math.ln
import kotlin.math.sin
import kotlin.math.roundToInt

/**
 * Basic coverage for [SleepStagerV2] (V7 Pillar 3b, reimplemented from @sunny-noop's recipe), the Android
 * twin of SleepStagerV2Tests.swift — the recipe that stages a normal user's nights, since the stored
 * `experimentalSleepV2` preference is default TRUE (#277 promoted it over V1; #351 extended it to every
 * strap family). Asserts the drop-in CONTRACT — same [SleepStager.stageSession] signature + return shape,
 * segments that tile [start, end] with canonical stage labels — and that the [SleepStageHealer] V1/V2
 * switch actually routes to V2 (its PARAMETER defaults to V1 byte for byte, which is the library contract,
 * not the product default).
 * NOT a fidelity claim against any reference: the cross-subject evidence behind the promotion is a
 * 44-subject leave-one-subject-out benchmark, and these unit tests do not re-measure it.
 */
class SleepStagerV2Test {

    private val dev = "test"

    /** 2025-06-10 00:00:00 UTC — fixed midnight, as in the other stager tests. */
    private val refMidnight = 1_749_513_600L

    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    private fun sleepHR(start: Long, durationS: Int, base: Int = 52): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = base + ((it / 60) % 3).toInt()) }

    private fun regularRR(start: Long, durationS: Int): List<RrInterval> =
        (0 until durationS).map { i ->
            val rsa = (40.0 * sin(2.0 * PI * i / 4.0)).roundToInt()  // ~0.25 Hz breathing
            RrInterval(deviceId = dev, ts = start + i, rrMs = 1000 + rsa)
        }

    // ── drop-in contract ─────────────────────────────────────────────────────────────────────────────

    @Test
    fun stagesTileTheWholeSpanContiguously() {
        val start = refMidnight + 3_600L
        val dur = 90 * 60
        val end = start + dur
        val segs = SleepStagerV2.stageSession(
            start = start, end = end,
            grav = stillGravity(start, dur), hr = sleepHR(start, dur), rr = regularRR(start, dur),
            resp = emptyList())

        assertFalse("a covered window must produce at least one segment", segs.isEmpty())
        assertEquals("first segment starts at `start`", start, segs.first().start)
        assertEquals("last segment ends at `end`", end, segs.last().end)
        for (i in 1 until segs.size) {
            assertEquals("segments tile with no gap/overlap", segs[i - 1].end, segs[i].start)
            assertTrue("each segment is non-empty", segs[i].end > segs[i].start)
        }
    }

    @Test
    fun onlyCanonicalStageLabels() {
        val start = refMidnight + 3_600L
        val dur = 80 * 60
        val segs = SleepStagerV2.stageSession(
            start = start, end = start + dur,
            grav = stillGravity(start, dur), hr = sleepHR(start, dur), rr = regularRR(start, dur),
            resp = emptyList())
        val allowed = setOf("wake", "light", "deep", "rem")
        for (s in segs) assertTrue("unexpected stage label ${s.stage}", s.stage in allowed)
    }

    @Test
    fun degenerateInputFallsBackToSingleLightBlock() {
        val start = refMidnight
        val end = start + 3_600L
        val segs = SleepStagerV2.stageSession(
            start = start, end = end,
            grav = listOf(GravitySample(deviceId = dev, ts = start, x = 0.0, y = 0.0, z = 1.0)),
            hr = emptyList(), rr = emptyList(), resp = emptyList())
        assertEquals(1, segs.size)
        assertEquals("light", segs.first().stage)
        assertEquals(start, segs.first().start)
        assertEquals(end, segs.first().end)
    }

    // ── the SleepStageHealer V1/V2 switch ──────────────────────────────────────────────────────────────

    /** The opt-in flag routes the heal's re-stage to V2; default (false) stays on V1, byte-identical. */
    @Test
    fun healerSwitchSelectsV2WhenFlagOn() {
        val start = refMidnight + 3_600L
        val dur = 6 * 60 * 60
        val end = start + dur - 1
        val grav = stillGravity(start, dur)
        val hr = sleepHR(start, dur)
        val rr = regularRR(start, dur)

        val v1 = SleepStageHealer.restageFromSamples(start, end, grav, hr, rr, emptyList())
        val v1Default = SleepStageHealer.restageFromSamples(
            start, end, grav, hr, rr, emptyList(), useExperimentalSleepV2 = false)
        val v2 = SleepStageHealer.restageFromSamples(
            start, end, grav, hr, rr, emptyList(), useExperimentalSleepV2 = true)

        assertNotNull("dense raw must stage on both paths", v1)
        assertNotNull(v2)
        assertEquals("default flag is V1 (byte-identical to the no-flag call)", v1, v1Default)
        assertTrue("V1 output is a segment array", v1!!.trimStart().startsWith("["))
        assertTrue("V2 output is a segment array", v2!!.trimStart().startsWith("["))
    }

    // ── 7.0.0: the V2 flag drives the NORMAL detected-night staging path ─────────────────────────────────

    /**
     * 7.0.0 regression: the "Experimental sleep staging (V2)" toggle must affect a NORMAL detected
     * night — not only the userEdited self-heal restage. With the flag ON, [SleepStager.detectSleep]
     * stages the accepted window with V2 (deep + REM present); with the flag OFF it returns the EXACT V1
     * result, so the byte-identical default (and the frozen-golden tests) is preserved. Android twin of
     * SleepStagerV2Tests.testDetectSleepThreadsV2FlagIntoNormalNight.
     */
    @Test
    fun detectSleepThreadsV2FlagIntoNormalNight() {
        // A 3 h still overnight window (anchored at 01:00 UTC → center ~02:30, clear of the daytime guard
        // band at the default tzOffset=0) with sleep-band HR + a regular R-R stream.
        val start = refMidnight + 3_600L
        val dur = 3 * 60 * 60
        val grav = stillGravity(start, dur)
        val hr = sleepHR(start, dur)
        val rr = regularRR(start, dur)

        // Flag OFF (the default) — V1 path.
        val v1Sessions = SleepStager.detectSleep(hr = hr, rr = rr, gravity = grav)
        assertEquals("the still night must be detected", 1, v1Sessions.size)
        val v1 = v1Sessions[0]
        // The detected window's stages MUST equal a direct V1 stageSession over the same span (proof the
        // default path is byte-identical and untouched by the new parameter).
        val v1Direct = SleepStager.stageSession(
            start = v1.start, end = v1.end, grav = grav, hr = hr, rr = rr, resp = emptyList())
        assertEquals("flag OFF must reproduce the exact V1 hypnogram", v1Direct, v1.stages)

        // Flag ON — the SAME detected window must now be staged by V2.
        val v2Sessions = SleepStager.detectSleep(hr = hr, rr = rr, gravity = grav, useSleepStagerV2 = true)
        assertEquals("detection is unchanged by the staging flag", 1, v2Sessions.size)
        val v2 = v2Sessions[0]
        assertEquals(v1.start, v2.start)
        assertEquals(v1.end, v2.end)
        // The hypnogram is V2's: it matches a direct V2 stageSession over the accepted span, and (proof the
        // flag actually flipped the engine) it expresses both deep and REM.
        val v2Direct = SleepStagerV2.stageSession(
            start = v2.start, end = v2.end, grav = grav, hr = hr, rr = rr, resp = emptyList())
        assertEquals("flag ON must produce the V2 hypnogram", v2Direct, v2.stages)
        val v2Stages = v2.stages.map { it.stage }.toSet()
        assertTrue("V2 night should express deep", "deep" in v2Stages)
        assertTrue("V2 night should express REM", "rem" in v2Stages)
    }

    // ── #277 frozen golden: pin the tuned V2 recipe (deepGateThresh / deep emission / transition row) ──────

    /** Fixed integer "breathing" wave — no float rounding, so Swift + Kotlin build byte-identical samples
     *  (Kotlin roundToInt is half-up, Swift .rounded() is half-away-from-zero; integers avoid the gap). */
    private fun rsaWave(ph: Int, i: Int): Int {
        val amp = intArrayOf(12, 60, 30, 20)[ph]
        return intArrayOf(0, amp, 0, -amp)[i % 4]
    }

    /**
     * A crafted 4-phase night (deep-favorable → high-RSA → mild → restless) staged by V2 must reproduce this
     * EXACT hypnogram. This locks the recipe's END-TO-END behaviour and — because the Swift twin
     * (`SleepStagerV2Tests.testFrozenGoldenHypnogram`) asserts the SAME sequence from byte-identical input —
     * proves the full staging path stays Swift↔Kotlin parity-identical (the whole Viterbi path, not just the
     * constants). It catches GROSS regressions; it is deliberately NOT the guard for the exact #277 tuned
     * VALUES — on this stark input reverting deepGateThresh/emission/transition doesn't move a boundary — those
     * are pinned directly in [tunedDeepBoundaryConstantsArePinned]. Input is integer-only / fixed-literal so the
     * two languages build identical samples. Regenerate deliberately if the recipe is intentionally retuned.
     */
    @Test
    fun frozenGoldenHypnogramPinsTheRecipeShapeAndParity() {
        val start = refMidnight + 3_600L
        val phase = 90 * 60
        val dur = phase * 4
        val grav = ArrayList<GravitySample>()
        val hr = ArrayList<HrSample>()
        val rr = ArrayList<RrInterval>()
        for (i in 0 until dur) {
            val ts = start + i
            val ph = i / phase
            val restless = ph == 3 && (i % 20) < 6
            grav.add(
                if (restless) GravitySample(dev, ts, x = 0.2, y = 0.15, z = 0.96)
                else GravitySample(dev, ts, x = 0.0, y = 0.0, z = 1.0))
            val bpm = when (ph) {
                0 -> 50
                1 -> 54 + intArrayOf(0, 1, 2, 3, 2, 1)[(i / 20) % 6]
                2 -> 56 + ((i / 60) % 4)
                else -> 66 + ((i / 30) % 6)
            }
            hr.add(HrSample(dev, ts, bpm = bpm))
            rr.add(RrInterval(dev, ts, rrMs = (60_000 / bpm) + rsaWave(ph, i)))
        }
        val segs = SleepStagerV2.stageSession(start, start + dur, grav, hr, rr, emptyList())
        val golden = listOf(
            Triple(0L, 5070L, "deep"),
            Triple(5070L, 5310L, "light"),
            Triple(5310L, 5550L, "rem"),
            Triple(5550L, 10740L, "light"),
            Triple(10740L, 16290L, "rem"),
            Triple(16290L, 21600L, "wake"))
        assertEquals("segment count", golden.size, segs.size)
        for (k in golden.indices) {
            assertEquals("seg $k start", start + golden[k].first, segs[k].start)
            assertEquals("seg $k end", start + golden[k].second, segs[k].end)
            assertEquals("seg $k stage", golden[k].third, segs[k].stage)
        }
    }

    // ── #930: the REM-latency guard is measured in MINUTES, not as a fraction of the session ────────────────

    /**
     * THE point of #930, and the assertion the previous shape could not even express: a 10-hour night and a
     * 3-hour fragment must receive the SAME REM-latency guard at the same minute after sleep onset. Swift twin:
     * `SleepStagerV2Tests.testRemLatencyGuardIsIdenticalAcrossSessionLengths`.
     *
     * Under the replaced `c < 0.12` step the two disagree by construction — 30 min into a 10 h night is
     * `c = 0.05` (suppressed by the full 3.0) while 30 min into a 3 h fragment is `c = 0.167` (not suppressed at
     * all), so the identical physiological instant got opposite treatment purely because of how long the wearer
     * stayed in bed. The guard is isolated from the `1.0 * c` REM ramp (which is CORRECTLY a fraction of the
     * session and legitimately differs between the two) by subtracting the ramp back out.
     */
    @Test
    fun remLatencyGuardIsIdenticalAcrossSessionLengths() {
        val longNight = 10.0 * 60.0   // 600 min
        val fragment = 3.0 * 60.0     // 180 min
        var minutes = 0.0
        while (minutes <= 180.0) {
            val cLong = minutes / longNight
            val cShort = minutes / fragment
            // Strip the fraction-of-session REM ramp; what remains is the latency guard alone.
            val guardLong = 1.0 * cLong - SleepStagerV2.cyclePrior(cLong, minutes)["rem"]!!
            val guardShort = 1.0 * cShort - SleepStagerV2.cyclePrior(cShort, minutes)["rem"]!!
            assertEquals(
                "guard at $minutes min must not depend on session length",
                guardLong, guardShort, 1e-12)
            assertEquals(guardLong, SleepStagerV2.remLatencyGuard(minutes), 1e-12)
            minutes += 2.5
        }
    }

    /**
     * Shape of the guard: full strength at onset, linear decay, exactly zero at and past `remLatencyMinutes`,
     * and clamped (never stronger than at onset) for the pre-onset epochs a mis-placed window start produces.
     * Also pins the two constants themselves, so a one-sided Swift/Kotlin edit fails immediately. Swift twin:
     * `SleepStagerV2Tests.testRemLatencyGuardShapeAndClamp`.
     */
    @Test
    fun remLatencyGuardShapeAndClamp() {
        val k = SleepStagerV2.remLatencyPenalty
        val m0 = SleepStagerV2.remLatencyMinutes
        assertEquals("K is pinned across platforms", 3.0, k, 0.0)
        assertEquals("M0 is pinned across platforms", 60.0, m0, 0.0)
        assertEquals("full penalty at onset", k, SleepStagerV2.remLatencyGuard(0.0), 1e-12)
        assertEquals("linear halfway", k / 2, SleepStagerV2.remLatencyGuard(m0 / 2), 1e-12)
        assertEquals("spent at M0", 0.0, SleepStagerV2.remLatencyGuard(m0), 1e-12)
        assertEquals("never negative later", 0.0, SleepStagerV2.remLatencyGuard(m0 + 500), 1e-12)
        // #271 can place the window start hours before real onset; the guard must stay bounded there.
        assertEquals("clamped pre-onset", k, SleepStagerV2.remLatencyGuard(-240.0), 1e-12)
        assertEquals(
            "the disabled-guard sentinel pass 1 uses must contribute nothing",
            0.0, SleepStagerV2.remLatencyGuard(Double.POSITIVE_INFINITY), 1e-12)
        var prev = Double.POSITIVE_INFINITY
        var m = -60.0
        while (m <= 120.0) {
            val g = SleepStagerV2.remLatencyGuard(m)
            assertTrue("guard must never increase with elapsed time", g <= prev + 1e-12)
            prev = g
            m += 1.0
        }
    }

    /**
     * The 5-minute sustained-sleep onset rule (10 epochs on the 30 s grid), measured against PSG onset on
     * sleep-accel at bias −3.8 min / MAE 7.4 min. A shorter sleep run must NOT establish onset. Swift twin:
     * `SleepStagerV2Tests.testSustainedSleepOnsetRule`.
     */
    @Test
    fun sustainedSleepOnsetRule() {
        val wake = List(6) { "awake" }
        // 9 epochs of sleep (4.5 min) is one short of the rule and must not count.
        assertEquals(null, SleepStagerV2.sustainedSleepOnset(wake + List(9) { "light" } + wake))
        // 10 epochs (5 min) does, and onset is the FIRST epoch of the run, not the tenth.
        assertEquals(6, SleepStagerV2.sustainedSleepOnset(wake + List(10) { "light" } + wake))
        // A brief run before a sustained one must not be mistaken for onset; the counter resets on wake.
        assertEquals(
            11,
            SleepStagerV2.sustainedSleepOnset(wake + List(4) { "rem" } + listOf("awake") + List(12) { "deep" }))
        assertEquals("an empty night has no onset", null, SleepStagerV2.sustainedSleepOnset(emptyList()))
        assertEquals("an all-wake window has no onset", null, SleepStagerV2.sustainedSleepOnset(wake))
    }

    /**
     * End-to-end: the same physiological night truncated to a shorter in-bed window must not shift where the
     * REM guard stops applying. Both windows start at the same instant and share byte-identical streams, so any
     * difference in the first ~60 min of the hypnogram would be the session-length dependence #930 is about.
     * Swift twin: `SleepStagerV2Tests.testGuardRegionDoesNotDependOnHowLongTheWearerStayedInBed`.
     */
    @Test
    fun guardRegionDoesNotDependOnHowLongTheWearerStayedInBed() {
        val start = refMidnight + 3_600L
        val longDur = 10 * 60 * 60
        val shortDur = 3 * 60 * 60
        val grav = stillGravity(start, longDur)
        val hr = sleepHR(start, longDur)
        val rr = regularRR(start, longDur)

        fun labels(dur: Int): List<String> {
            val segs = SleepStagerV2.stageSession(start, start + dur, grav, hr, rr, emptyList())
            val out = ArrayList<String>()
            var t = start
            while (t < start + dur) {
                out.add(segs.firstOrNull { it.start <= t && t < it.end }?.stage ?: "wake")
                t += 30
            }
            return out
        }
        val long = labels(longDur)
        val short = labels(shortDur)
        // Over the first hour — the whole span the guard touches — the two windows must agree, because the
        // guard reaches the SAME 60 minutes past onset in both. Under `c < 0.12` the 10 h window was guarded
        // for 72 min and the 3 h window for only 21.6 min, so they could not agree here by construction.
        val guardEpochs = (SleepStagerV2.remLatencyMinutes * 60 / 30).toInt()
        for (i in 0 until guardEpochs) {
            assertEquals(
                "epoch $i (minute ${i * 0.5}) differs — the guard must not scale with session length",
                long[i], short[i])
        }
    }

    /**
     * Directly pin the #277 deep-boundary tune — the reliable guard the end-to-end golden can't be (a golden is
     * only sensitive where the input sits near a decision boundary). Asserts the exact tuned VALUES and their
     * Swift↔Kotlin equality (twin: `SleepStagerV2Tests.testTunedDeepBoundaryConstantsArePinned`), so a fat-finger
     * or a one-sided edit to deepGateThresh / the deep transition row fails immediately. The row-sum invariant
     * catches a renormalisation typo in the hand-edited matrix. (The inline deep EMISSION weights aren't named
     * constants, so they stay guarded only at the gross level by the golden — retune deliberately.)
     */
    @Test
    fun tunedDeepBoundaryConstantsArePinned() {
        assertEquals(0.25, SleepStagerV2.deepGateThresh, 0.0)
        assertEquals(
            mapOf("deep" to 0.86, "rem" to 0.007, "light" to 0.126, "awake" to 0.007),
            SleepStagerV2.transition["deep"])
        for ((from, row) in SleepStagerV2.transition) {
            assertEquals("transition row '$from' must sum to 1.0", 1.0, row.values.sum(), 1e-9)
        }
    }

    /**
     * Pin the AWAKE transition row directly, for the same reason the deep row is pinned: the end-to-end golden
     * is only sensitive where its own input sits near a decision boundary, and it does NOT move when this row
     * changes — so without this assertion the row is effectively unguarded. Twin:
     * `SleepStagerV2Tests.testWakeRowForbidsDirectDescentIntoDeepOrRem`.
     *
     * The zeros are the physiological claim: sleep onset descends through N1/N2, so wake never transitions
     * straight into N3 or REM. They are also why [SleepStagerV2.viterbi] floors the log at 1e-9 — asserted here
     * so the two can never drift apart and reintroduce ln(0) = -Inf.
     */
    @Test
    fun wakeRowForbidsDirectDescentIntoDeepOrRem() {
        assertEquals(
            mapOf("deep" to 0.0, "rem" to 0.0, "light" to 0.10, "awake" to 0.90),
            SleepStagerV2.transition["awake"])
        // A zeroed entry must reach the lattice as a large finite penalty, never -Inf.
        val lp = ln(maxOf(SleepStagerV2.transition["awake"]!!["deep"]!!, 1e-9))
        assertTrue("a zeroed transition must not produce a non-finite log-weight", lp.isFinite())
    }
}
