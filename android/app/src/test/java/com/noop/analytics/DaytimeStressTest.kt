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
}
