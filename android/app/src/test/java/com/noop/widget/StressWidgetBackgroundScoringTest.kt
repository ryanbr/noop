package com.noop.widget

import com.noop.analytics.DaytimeStress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

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
    fun foregroundProducerChecksPlacementBeforeScoring() {
        var root = File(System.getProperty("user.dir") ?: ".").canonicalFile
        var source: String? = null
        repeat(4) {
            val candidate = File(root, "android/app/src/main/java/com/noop/ui/AppViewModel.kt")
            if (candidate.isFile && source == null) source = candidate.readText()
            root = root.parentFile ?: root
        }
        val viewModel = source
            ?: error("AppViewModel.kt not found - this test must not pass by default")
        val foregroundProducer = Regex(
            """val\s+stressCurve\s*=\s*if\s*\(WidgetSnapshotStore\.hasStressWidget\(appContext\)\)\s*\{\s*com\.noop\.widget\.StressWidgetProducer\.todayCurve"""
        )

        assertTrue(
            "AppViewModel must check for a placed stress widget before reading the day",
            foregroundProducer.containsMatchIn(viewModel),
        )
    }

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

    // #2120: what the stamp becomes once the attempt's outcome is known.

    /**
     * The case the report is about: a placed widget whose read came back null. The stamp rewinds to a
     * short retry floor, so the next emission tries again instead of the widget sitting blank for a
     * full interval while the wearer wonders why opening the app fixes it.
     */
    @Test
    fun `a placed widget whose read failed retries at the short floor`() {
        val now = 1_000_000L
        val stamp = StressWidgetProducer.stampAfterAttempt(
            nowMs = now, producedCurve = false, widgetPlaced = true,
            intervalMs = 15L * 60_000L, retryMs = 60_000L,
        )
        assertFalse(StressWidgetProducer.shouldRescore(now, stamp, 15L * 60_000L))
        assertTrue(StressWidgetProducer.shouldRescore(now + 60_000L, stamp, 15L * 60_000L))
    }

    /**
     * No widget placed is not a failure, it is the right answer, so it keeps the full interval. Retrying
     * sooner would re-run the placement check on a collector driven by live heart rate, which is the cost
     * the early stamp exists to avoid.
     */
    @Test
    fun `no widget placed keeps the full interval`() {
        val now = 1_000_000L
        val stamp = StressWidgetProducer.stampAfterAttempt(
            nowMs = now, producedCurve = false, widgetPlaced = false, intervalMs = 15L * 60_000L,
        )
        assertEquals(now, stamp)
        assertFalse(StressWidgetProducer.shouldRescore(now + 60_000L, stamp, 15L * 60_000L))
    }

    /**
     * The case the report is really about, and the one an earlier pass of this change left unfixed.
     *
     * The placement check fails closed, so a Glance or binder hiccup returns the same `false` a settled
     * "no widget placed" does. Treating them alike spends the whole interval on a widget that IS placed
     * and IS blank, which is the fifteen minutes the wearer works around by opening the app. A null
     * placement therefore retries at the short floor, exactly as a failed read does.
     */
    @Test
    fun `an unanswered placement check retries rather than spending the interval`() {
        val now = 1_000_000L
        val stamp = StressWidgetProducer.stampAfterAttempt(
            nowMs = now, producedCurve = false, widgetPlaced = null,
            intervalMs = 15L * 60_000L, retryMs = 60_000L,
        )
        assertFalse(StressWidgetProducer.shouldRescore(now, stamp, 15L * 60_000L))
        assertTrue(StressWidgetProducer.shouldRescore(now + 60_000L, stamp, 15L * 60_000L))
    }

    /**
     * And the distinction holds in the other direction: a SETTLED no keeps the full interval, so a device
     * with no stress widget does not start re-running the placement check on a hot collector. The two
     * cases used to be one value; this pins that they now behave differently.
     */
    @Test
    fun `a settled no and an unanswered check are told apart`() {
        val now = 1_000_000L
        val settled = StressWidgetProducer.stampAfterAttempt(
            nowMs = now, producedCurve = false, widgetPlaced = false, intervalMs = 15L * 60_000L,
        )
        val unknown = StressWidgetProducer.stampAfterAttempt(
            nowMs = now, producedCurve = false, widgetPlaced = null, intervalMs = 15L * 60_000L,
        )
        assertEquals(now, settled)
        assertNotEquals(settled, unknown)
    }

    /** A successful score keeps the full interval, which is the unchanged behaviour. */
    @Test
    fun `a produced curve keeps the full interval`() {
        val now = 1_000_000L
        val stamp = StressWidgetProducer.stampAfterAttempt(
            nowMs = now, producedCurve = true, widgetPlaced = true, intervalMs = 15L * 60_000L,
        )
        assertEquals(now, stamp)
        assertFalse(StressWidgetProducer.shouldRescore(now + 60_000L, stamp, 15L * 60_000L))
    }

    /**
     * A retry floor longer than the interval must not rewind INTO the future, which would push the next
     * attempt further out than doing nothing at all.
     */
    @Test
    fun `a retry floor longer than the interval never delays the next attempt`() {
        val now = 1_000_000L
        val stamp = StressWidgetProducer.stampAfterAttempt(
            nowMs = now, producedCurve = false, widgetPlaced = true,
            intervalMs = 60_000L, retryMs = 15L * 60_000L,
        )
        assertEquals(now, stamp)
    }

    /**
     * An unanswered placement check that then SCORES keeps the full interval, like any other success.
     *
     * The caller scores on unknown rather than skipping, because a device whose Glance check fails
     * persistently would otherwise never score at all and the widget would stay blank. Once a curve
     * exists there is nothing to retry, so the outcome, not the placement, decides the stamp.
     */
    @Test
    fun `an unanswered check that still produced a curve keeps the full interval`() {
        val now = 1_000_000L
        val stamp = StressWidgetProducer.stampAfterAttempt(
            nowMs = now, producedCurve = true, widgetPlaced = null, intervalMs = 15L * 60_000L,
        )
        assertEquals(now, stamp)
        assertFalse(StressWidgetProducer.shouldRescore(now + 60_000L, stamp, 15L * 60_000L))
    }
}
