package com.noop.widget

import com.noop.analytics.DaytimeStress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The stress widget's two blank states, and the gate that stops it staying blank.
 *
 * The curve used to be scored ONLY by `AppViewModel`, which runs while the app is open, while the BLE
 * service, the widget's actual heartbeat, pushed heart rate without ever scoring stress. `load` drops
 * any curve that is not today's, so the widget reset to a bare dash every midnight and nothing refilled
 * it until the app happened to be opened during waking hours. For anyone who uses the widget INSTEAD of
 * opening the app it read as permanently broken.
 *
 * The service now scores too, throttled, because its collector runs at the live heart-rate rate.
 */
class StressWidgetBackgroundScoringTest {
    private val interval = 15L * 60L * 1000L

    @Test
    fun theFirstTickAfterLaunchScores() {
        // 0 means "not yet this process". If this were treated as a recent score the widget would stay
        // blank for a whole interval after every launch, which is the state being fixed.
        assertTrue(StressWidgetProducer.shouldRescore(nowMs = 1_700_000_000_000, lastScoreAtMs = 0L, intervalMs = interval))
    }

    @Test
    fun aTickInsideTheIntervalDoesNotRescore() {
        val now = 1_700_000_000_000
        assertFalse(StressWidgetProducer.shouldRescore(now, now - (interval - 1), interval))
        // The collector runs on live heart rate, so this is the common case by a wide margin.
        assertFalse(StressWidgetProducer.shouldRescore(now, now - 1_000, interval))
    }

    @Test
    fun theIntervalBoundaryItselfRescores() {
        val now = 1_700_000_000_000
        assertTrue(StressWidgetProducer.shouldRescore(now, now - interval, interval))
        assertTrue(StressWidgetProducer.shouldRescore(now, now - (interval + 1), interval))
    }

    @Test
    fun theScoredWindowIsSixAmToTenPm() {
        // The window the timeline actually scores. A blank OUTSIDE it is "nothing until morning"; a
        // blank inside it is "no scorable hour yet", and the widget says which.
        assertEquals(6, DaytimeStress.wakingStartHour)
        assertEquals(22, DaytimeStress.wakingEndHour)
        assertTrue(DaytimeStress.isWakingHourOfDay(6))
        assertTrue(DaytimeStress.isWakingHourOfDay(11))
        assertTrue(DaytimeStress.isWakingHourOfDay(21))
        // Both ends are exclusive-at-the-top: 22:00 is already outside.
        assertFalse(DaytimeStress.isWakingHourOfDay(22))
        assertFalse(DaytimeStress.isWakingHourOfDay(5))
    }

    @Test
    fun theHoursBehindTheReportedBlankAreOutsideTheWindow() {
        // The screenshot that prompted this was taken at 01:02, and the log at 11:20 was inside the
        // window. Pinning both keeps the two states distinguishable rather than collapsing into one.
        assertFalse(DaytimeStress.isWakingHourOfDay(1))
        assertFalse(DaytimeStress.isWakingHourOfDay(0))
        assertTrue(DaytimeStress.isWakingHourOfDay(11))
    }

    @Test
    fun theBucketFormAndTheHourFormAgree() {
        // The two must not drift: the widget asks by hour, the scorer asks by bucket, one rule.
        for (h in 0..23) {
            val bucketAtHour = h.toLong() * 3600L
            assertEquals(
                "hour $h",
                DaytimeStress.isWakingHourOfDay(h),
                DaytimeStress.isWakingHour(bucketAtHour),
            )
        }
    }
}
