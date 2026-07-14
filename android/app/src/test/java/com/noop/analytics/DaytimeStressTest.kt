package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests DaytimeStress.analyze — the intraday (hour-by-hour) autonomic stress timeline.
 * Pure-function tests; no DB. Kotlin twin of the StrandAnalytics DaytimeStressTests.
 */
class DaytimeStressTest {

    /** Fill one local hour-of-day with `n` 1 Hz HR samples at `bpm` (UTC, tz offset 0). */
    private fun hourHr(hour: Int, bpm: Int, n: Int = DaytimeStress.minHourHrSamples): List<HrSample> {
        val base = hour.toLong() * 3_600L
        return (0 until n).map { HrSample(deviceId = "t", ts = base + it, bpm = bpm) }
    }

    /** R-R for one hour with a controllable beat-to-beat jitter (drives RMSSD). */
    private fun hourRrVariable(hour: Int, rrMs: Int, jitter: Int, n: Int = 60): List<RrInterval> {
        val base = hour.toLong() * 3_600L
        return (0 until n).map {
            RrInterval(deviceId = "t", ts = base + it * 50L, rrMs = rrMs + if (it % 2 == 0) jitter else -jitter)
        }
    }

    @Test
    fun sleepHoursInTheWindow_doNotShiftTheWakingTimeline() {
        // Regression (#357): the calm reference is built from the WAKING hours that are actually
        // scored, not the whole 24 h. The analysis window always starts at local midnight, so the
        // current day routinely carries several hours of sleep — the calmest, lowest-HR stretch of
        // the day. If those night hours leak into the reference they drag the "calm" anchor far
        // below every waking hour, inflating an ordinary calm day into sustained high stress
        // (tripping the passive Breathe nudge). So adding calm sleep hours to the input must NOT
        // change the waking timeline.
        val wakingBpm = listOf(62, 64, 63, 65, 64, 63, 62, 64, 66, 63, 64, 65) // hours 6..17
        val waking = (6..17).flatMapIndexed { i, h -> hourHr(h, wakingBpm[i]) }
        val sleepBpm = listOf(50, 51, 52, 51, 50, 53) // hours 0..5
        val sleep = (0..5).flatMapIndexed { i, h -> hourHr(h, sleepBpm[i]) }

        val noRr = emptyList<RrInterval>()
        val wakingOnly = DaytimeStress.analyze(waking, noRr)
        val withSleep = DaytimeStress.analyze(sleep + waking, noRr)

        assertEquals(
            "sleep hours sharing the window must not change the sustained-high verdict",
            wakingOnly.sustainedHigh, withSleep.sustainedHigh,
        )
        for (h in 6..17) {
            val withLvl = withSleep.scored.firstOrNull { it.hour == h }?.level
            val withoutLvl = wakingOnly.scored.firstOrNull { it.hour == h }?.level
            assertNotNull("waking hour $h should be scored in both runs", withLvl)
            assertNotNull("waking hour $h should be scored in both runs", withoutLvl)
            assertEquals(
                "the night's sleep hours leaked into the daytime reference and shifted waking hour $h",
                withoutLvl!!, withLvl!!, 1e-9,
            )
        }
        // The plain sanity check the bug violated: an ordinary calm day is not "sustained high".
        assertFalse(
            "a calm desk day must not read as sustained high stress",
            withSleep.sustainedHigh,
        )
    }

    // MARK: - Motion gate (Kotlin twin of the Swift gate tests)

    /**
     * Gravity for one local hour. [activeFraction] of the records step far enough between
     * consecutive samples to clear WorkoutDetector.motionThreshold (0.20 g L2); the rest hold still.
     */
    private fun hourGravity(hour: Int, activeFraction: Double, n: Int = 120): List<GravitySample> {
        val base = hour.toLong() * 3_600L
        val activeCount = Math.round(n * activeFraction).toInt()
        return (0 until n).map { i ->
            val x = if (i < activeCount && i % 2 == 0) 0.5 else 0.0
            GravitySample(deviceId = "t", ts = base + i * 30L, x = x, y = 0.0, z = 1.0)
        }
    }

    @Test
    fun emptyGravityIsByteIdenticalToNoGravity() {
        var hr = emptyList<HrSample>()
        for (h in listOf(8, 9, 10, 11)) hr = hr + hourHr(h, 60 + (h - 8) * 5)
        val withoutGravity = DaytimeStress.analyze(hr, emptyList())
        val withEmptyGravity = DaytimeStress.analyze(hr, emptyList(), emptyList())
        assertEquals(withoutGravity, withEmptyGravity)
        assertEquals(0, withEmptyGravity.activityMaskedHours)
        assertFalse(withEmptyGravity.hours.any { it.maskedForActivity })
    }

    @Test
    fun ambulatoryHourIsMaskedNotScored() {
        var hr = emptyList<HrSample>()
        for (h in listOf(8, 9, 10)) hr = hr + hourHr(h, 60)
        hr = hr + hourHr(11, 110)   // the walk

        val unGated = DaytimeStress.analyze(hr, emptyList())
        assertNotNull(
            "precondition: without gravity the ambulatory hour is scored as stress",
            unGated.scored.firstOrNull { it.hour == 11 }?.level,
        )

        var gravity = emptyList<GravitySample>()
        for (h in listOf(8, 9, 10)) gravity = gravity + hourGravity(h, 0.0)
        gravity = gravity + hourGravity(11, 1.0)

        val gated = DaytimeStress.analyze(hr, emptyList(), gravity)
        val masked = gated.hours.firstOrNull { it.hour == 11 }
        assertNotNull(masked)
        assertNull("an ambulatory hour must not be scored", masked!!.level)
        assertTrue(
            "the hour must report WHY it is unscored — masked, not no-data",
            masked.maskedForActivity,
        )
        assertEquals(
            "the reading itself is still reported, only the score is withheld",
            110.0, masked.meanHr!!, 1e-9,
        )
        assertEquals(1, gated.activityMaskedHours)
    }

    @Test
    fun stillHourIsStillScoredWhenGravityPresent() {
        var hr = emptyList<HrSample>()
        var gravity = emptyList<GravitySample>()
        for (h in listOf(8, 9, 10, 11)) {
            hr = hr + hourHr(h, if (h == 11) 85 else 60)
            gravity = gravity + hourGravity(h, 0.0)
        }
        val r = DaytimeStress.analyze(hr, emptyList(), gravity)
        assertEquals("a still day must have nothing masked", 0, r.activityMaskedHours)
        assertNotNull(
            "a stationary elevated-HR hour is exactly what the timeline SHOULD score",
            r.scored.firstOrNull { it.hour == 11 }?.level,
        )
    }

    @Test
    fun lightMovementBelowFractionDoesNotMask() {
        var hr = emptyList<HrSample>()
        var gravity = emptyList<GravitySample>()
        for (h in listOf(8, 9, 10, 11)) {
            hr = hr + hourHr(h, 60)
            gravity = gravity + hourGravity(h, if (h == 10) 0.10 else 0.0)
        }
        val r = DaytimeStress.analyze(hr, emptyList(), gravity)
        assertEquals(
            "10 % ambulatory is below activityMaskFraction (0.30) and must not mask the hour",
            0, r.activityMaskedHours,
        )
    }

    @Test
    fun postActivityShadowMasksOnlyWhileHrStaysElevated() {
        fun day(followingBpm: Int): DaytimeStress.Result {
            var hr = emptyList<HrSample>()
            var gravity = emptyList<GravitySample>()
            for (h in listOf(8, 9, 10, 13)) {
                hr = hr + hourHr(h, 60)
                gravity = gravity + hourGravity(h, 0.0)
            }
            hr = hr + hourHr(11, 120)                 // the workout hour
            gravity = gravity + hourGravity(11, 1.0)
            hr = hr + hourHr(12, followingBpm)        // the shadow hour, now still
            gravity = gravity + hourGravity(12, 0.0)
            return DaytimeStress.analyze(hr, emptyList(), gravity)
        }
        assertTrue(
            "an unrecovered post-exercise hour must be masked, not read as stress",
            day(100).hours.firstOrNull { it.hour == 12 }?.maskedForActivity ?: false,
        )
        assertFalse(
            "once HR is back at the calm reference the shadow must not keep masking",
            day(60).hours.firstOrNull { it.hour == 12 }?.maskedForActivity ?: true,
        )
    }

    @Test
    fun maskedHoursAreExcludedFromTheCalmReference() {
        var stillHr = emptyList<HrSample>()
        var stillGravity = emptyList<GravitySample>()
        for (h in listOf(8, 9, 10, 13)) {
            stillHr = stillHr + hourHr(h, if (h == 13) 80 else 60)
            stillGravity = stillGravity + hourGravity(h, 0.0)
        }
        val withoutWorkout = DaytimeStress.analyze(stillHr, emptyList(), stillGravity)

        val withHr = stillHr + hourHr(11, 130)
        val withGravity = stillGravity + hourGravity(11, 1.0)
        val withWorkout = DaytimeStress.analyze(withHr, emptyList(), withGravity)

        val before = withoutWorkout.scored.firstOrNull { it.hour == 13 }?.level
        val after = withWorkout.scored.firstOrNull { it.hour == 13 }?.level
        assertNotNull(before)
        assertNotNull(after)
        assertEquals(
            "a masked exertion hour leaked into the calm reference and moved an unrelated hour's score",
            before!!, after!!, 1e-9,
        )
    }

    // MARK: - Additivity: the `mode` parameter is opt-in, day-relative stays the default

    @Test
    fun dayRelativeDefaultIsByteIdenticalToExplicitMode() {
        // The additive `mode` parameter defaults to DayRelative. Confirms the implicit call
        // (every pre-existing call site, unmodified) and the explicit DayRelative case produce a
        // BYTE-IDENTICAL Result — every field, not just the pre-existing ones — proving the new
        // mode is purely additive and never a silent behaviour change.
        val hr = ArrayList<HrSample>()
        for (h in listOf(8, 9, 10)) hr += hourHr(h, 58)
        hr += hourHr(13, 120)
        hr += hourHr(14, 125)
        hr += hourHr(15, 130)
        val rr = ArrayList<RrInterval>()
        rr += hourRrVariable(9, 900, 40)
        rr += hourRrVariable(14, 900, 5)

        val implicit = DaytimeStress.analyze(hr, rr, tzOffsetSeconds = 3_600L)
        val explicit = DaytimeStress.analyze(hr, rr, tzOffsetSeconds = 3_600L,
            mode = DaytimeStress.ScoringMode.DayRelative)
        assertEquals(
            "omitting `mode` must be byte-identical to passing DayRelative explicitly",
            implicit, explicit,
        )
    }

    @Test
    fun highStressMinutesCountsAllHighBandHoursNotJustTheTrailingRun() {
        // An isolated morning spike, then a calm run ending the day: sustainedHigh only cares about
        // the TRAILING run (and must be false here, since the day ends calm), but highStressMinutes
        // is a day-wide tally and must still count the earlier spike hour — proving it is computed
        // independently, not derived from sustainedRun.
        val hr = ArrayList<HrSample>()
        hr += hourHr(7, 130)   // isolated high spike
        hr += hourHr(8, 60)
        hr += hourHr(9, 60)
        hr += hourHr(10, 60)
        hr += hourHr(11, 60)   // trailing hour is calm -> NOT sustained
        val r = DaytimeStress.analyze(hr, emptyList())

        assertFalse("the trailing hour is calm, so sustained-high must not fire", r.sustainedHigh)
        val expectedHighHours = r.scored.count { it.level!! >= DaytimeStress.highBandFloor }
        assertTrue("the isolated morning spike should read as high band", expectedHighHours > 0)
        assertEquals(expectedHighHours * (DaytimeStress.bucketSeconds / 60L).toInt(), r.highStressMinutes)
        assertFalse("day-relative mode never sets the baseline-relative fallback flag", r.hrOnlyFallback)
    }

    // MARK: - Baseline-relative mode (Oura-style, vs a PERSONAL rolling baseline)
    //
    // Fixtures below use a 65 bpm personal HR baseline (matching the ~65 bpm pooled
    // 10th-percentile figure from the validated 26-day Oura-reference correlation — see
    // DaytimeStress.baselineRelativeHighMarginBPM) and elevations measured from it in terms of that
    // validated ~15 bpm margin, so the expected band crossings are exact, not approximate.

    @Test
    fun marginToSigmaLandsExactlyOnBand() {
        // The validated 15 bpm margin over baseline must land EXACTLY on highBandFloor (2.0) on the
        // shared squash curve — the core identity baseline-relative scoring relies on.
        val sd = DaytimeStress.marginToSigma(DaytimeStress.baselineRelativeHighMarginBPM, DaytimeStress.highBandFloor)
        assertEquals(
            DaytimeStress.highBandFloor,
            DaytimeStress.squash(DaytimeStress.baselineRelativeHighMarginBPM / sd),
            1e-9,
        )
    }

    @Test
    fun baselineRelativeModeRecoversMultipleInjectedElevations() {
        // Personal daytime-HR baseline: 20 constant "days" at 65 bpm converges the EWMA center to
        // exactly 65 (spread is folded but NOT used for the HR high-band threshold).
        val hrBaseline = Baselines.foldHistory(List(20) { 65.0 }, Baselines.daytimeHRCfg)
        assertEquals(65.0, hrBaseline.baseline, 1e-6)

        // FOUR distinct injected HR elevations across the SAME day's waking hours — the repo's
        // derived-signal rule requires recovering MULTIPLE injected values, not a single high-vs-low
        // pair. 65 (at baseline), 72 (+7, mild), 80 (+15, exactly the validated margin), 95 (+30).
        val levels = listOf(8 to 65, 10 to 72, 13 to 80, 16 to 95)
        val hr = ArrayList<HrSample>()
        for ((h, bpm) in levels) hr += hourHr(h, bpm)

        val r = DaytimeStress.analyze(hr, emptyList(),
            mode = DaytimeStress.ScoringMode.BaselineRelative(hrBaseline, null))
        val scores = levels.map { pair -> r.scored.first { it.hour == pair.first }.level!! }

        // Strictly increasing with the injected elevation — all four levels recovered, in order.
        for (i in 1 until scores.size) {
            assertTrue(
                "hour ${levels[i].first} (${levels[i].second} bpm) should score higher than hour " +
                    "${levels[i - 1].first} (${levels[i - 1].second} bpm)",
                scores[i] > scores[i - 1],
            )
        }
        // The at-baseline hour reads at the 1.5 midpoint; +15 bpm (the validated margin) lands
        // exactly on highBandFloor; the most-elevated hour clears well past it.
        assertEquals(1.5, scores[0], 0.05)
        assertEquals(
            "the validated +15 bpm margin should land exactly on highBandFloor",
            DaytimeStress.highBandFloor, scores[2], 0.01,
        )
        assertTrue(scores.last() > DaytimeStress.highBandFloor)
        assertTrue("rmssd = null must flag the HR-only fallback", r.hrOnlyFallback)
    }

    @Test
    fun baselineRelativeCalmDayAtPersonalBaselineReadsLowNotHigh() {
        val hrBaseline = Baselines.foldHistory(List(20) { 65.0 }, Baselines.daytimeHRCfg)
        val hr = ArrayList<HrSample>()
        for (h in listOf(8, 10, 13, 16)) hr += hourHr(h, 65)   // every hour sits exactly at baseline
        val r = DaytimeStress.analyze(hr, emptyList(),
            mode = DaytimeStress.ScoringMode.BaselineRelative(hrBaseline, null))

        for (p in r.scored) {
            assertEquals("a day flat at the personal baseline should read ~1.5, not elevated",
                1.5, p.level!!, 0.05)
        }
        assertEquals(0, r.highStressMinutes)
        assertFalse(r.sustainedHigh)
    }

    @Test
    fun baselineRelativeElevatedDayProducesHighStressMinutes() {
        val hrBaseline = Baselines.foldHistory(List(20) { 65.0 }, Baselines.daytimeHRCfg)
        val hr = ArrayList<HrSample>()
        for (h in 8..16) hr += hourHr(h, 95)   // +30 bpm — twice the validated high-band margin
        val r = DaytimeStress.analyze(hr, emptyList(),
            mode = DaytimeStress.ScoringMode.BaselineRelative(hrBaseline, null))

        assertTrue(r.highStressMinutes > 0)
        assertEquals(
            r.scored.count { it.level!! >= DaytimeStress.highBandFloor } * (DaytimeStress.bucketSeconds / 60L).toInt(),
            r.highStressMinutes,
        )
        for (p in r.scored) assertTrue(p.level!! >= DaytimeStress.highBandFloor)
    }

    @Test
    fun baselineRelativeNilRMSSDFallsBackToHROnlyAndFlagsDegraded() {
        // An imported, Oura-era day: no personal RMSSD baseline exists yet (rmssd = null) and no R-R
        // stream is available either. The read must still complete honestly, never crash.
        val hrBaseline = Baselines.foldHistory(List(20) { 65.0 }, Baselines.daytimeHRCfg)
        val hr = ArrayList<HrSample>()
        for (h in listOf(9, 14)) hr += hourHr(h, 80)   // right at the validated +15 bpm margin
        val r = DaytimeStress.analyze(hr, emptyList(),
            mode = DaytimeStress.ScoringMode.BaselineRelative(hrBaseline, null))

        assertTrue(r.hrOnlyFallback)
        assertFalse("HR-only scoring must still produce a timeline", r.scored.isEmpty())
        for (p in r.scored) assertNotNull(p.level)
    }

    @Test
    fun baselineRelativeUsesRMSSDBaselineWhenAvailable() {
        // Personal baselines: HR steady at 65 bpm, RMSSD steady at 40 ms (both spread-floored).
        val hrBaseline = Baselines.foldHistory(List(20) { 65.0 }, Baselines.daytimeHRCfg)
        val rmssdBaseline = Baselines.foldHistory(List(20) { 40.0 }, Baselines.daytimeRMSSDCfg)

        val hr = ArrayList<HrSample>()
        val rr = ArrayList<RrInterval>()
        for (h in listOf(9, 14)) hr += hourHr(h, 65)     // HR AT baseline in both hours — isolates RMSSD
        rr += hourRrVariable(9, 900, 40)                  // normal variability
        rr += hourRrVariable(14, 900, 2)                  // suppressed HRV -> more stressed

        val r = DaytimeStress.analyze(hr, rr,
            mode = DaytimeStress.ScoringMode.BaselineRelative(hrBaseline, rmssdBaseline))
        assertFalse("an RMSSD baseline was supplied — no fallback", r.hrOnlyFallback)
        val normal = r.scored.first { it.hour == 9 }.level!!
        val suppressed = r.scored.first { it.hour == 14 }.level!!
        assertTrue(
            "suppressed RMSSD vs. the personal baseline should read MORE stressed than normal variability",
            suppressed > normal,
        )
    }
}
