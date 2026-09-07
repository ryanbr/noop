package com.noop.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Pins the widget cost counters. These exist to answer a field report ("battery drain feels worse
 * with the widget enabled") from an export rather than from an argument about the code, so the thing
 * worth testing is that the numbers mean what the line claims they mean.
 */
class WidgetTelemetryTest {

    @Before
    fun setUp() {
        WidgetTelemetry.resetForTest()
        HrTraceSeen.resetForTest()
    }

    private val t0 = 1_700_000_000_000L

    /**
     * The gate is the whole reason a ~1/s live-HR stream does not become a push per second, so the
     * offered count has to include what was dropped. Reporting only what got through would make a
     * broken throttle look like a quiet one.
     */
    @Test
    fun offeredCountIncludesWhatTheGateDropped() {
        WidgetTelemetry.notePushAdmitted(t0)
        repeat(59) { WidgetTelemetry.notePushGated(t0 + it * 1000L) }
        val s = WidgetTelemetry.snapshot(t0 + 60_000L)
        assertEquals(1, s.pushesAdmitted)
        assertEquals(59, s.pushesGated)
        assertTrue("1 pushed / 60 offered" in s.render())
    }

    /** A rate over one minute of uptime is the figure a drain question turns on. */
    @Test
    fun ratesAreExtrapolatedFromUptime() {
        repeat(10) { WidgetTelemetry.notePushAdmitted(t0 + it * 60_000L) }
        repeat(10) { WidgetTelemetry.noteRender(bytes = 512 * 1024, elapsedMs = 4) }
        val s = WidgetTelemetry.snapshot(t0 + 600_000L)   // 10 minutes
        assertEquals(60.0, s.pushesPerHour!!, 0.001)      // 10 pushes in 10m = 60/h
        assertEquals(512L, s.meanRenderBytes!! / 1024)
        // 10 x 512KB in 10 minutes = 30MB/h.
        assertEquals(30.0, s.renderBytesPerHour!! / 1_048_576.0, 0.01)
    }

    /**
     * A rate computed from a few seconds of uptime is noise wearing a number's clothes, and this line
     * goes in front of someone deciding whether to change the refresh cadence.
     */
    @Test
    fun noRateIsClaimedUnderAMinuteOfUptime() {
        WidgetTelemetry.notePushAdmitted(t0)
        val s = WidgetTelemetry.snapshot(t0 + 5_000L)
        assertNull(s.pushesPerHour)
        assertNull(s.renderBytesPerHour)
        assertEquals(1, s.pushesAdmitted)
    }

    /** The absence of widget activity is itself an answer to a drain report, so it must be stated. */
    @Test
    fun aSessionWithNoPushesSaysSoRatherThanRenderingNothing() {
        assertEquals("Widgets:     no pushes this app session", WidgetTelemetry.snapshot(t0).render())
    }

    @Test
    fun maxDrawTimeIsTheMaxNotTheLast() {
        WidgetTelemetry.noteRender(bytes = 1024, elapsedMs = 40)
        WidgetTelemetry.noteRender(bytes = 1024, elapsedMs = 2)
        val s = WidgetTelemetry.snapshot(t0 + 60_000L)
        assertEquals(40, s.renderMsMax)
        assertEquals(21, s.renderMs / s.renders)
    }

    // MARK: - HrTraceSeen

    /**
     * A push carrying no live sample appends no point, so the next draw reproduces the previous
     * bitmap exactly. That is the saving a future cache would take, and it is only worth taking if
     * this counts it honestly.
     */
    @Test
    fun anUnchangedSeriesIsRecognisedAsARepeat() {
        val series = listOf(HrPoint(ts = 100, bpm = 60), HrPoint(ts = 160, bpm = 62))
        assertFalse("the first draw is never a repeat", HrTraceSeen.repeat(series, 800, 250, false))
        assertTrue(HrTraceSeen.repeat(series, 800, 250, false))
        assertTrue(HrTraceSeen.repeat(series, 800, 250, false))
    }

    /** A new bucket is a different picture. */
    @Test
    fun anAdvancedSeriesIsNotARepeat() {
        val series = listOf(HrPoint(ts = 100, bpm = 60))
        HrTraceSeen.repeat(series, 800, 250, false)
        assertFalse(HrTraceSeen.repeat(series + HrPoint(ts = 160, bpm = 62), 800, 250, false))
    }

    /**
     * Same points, different box or theme, is a genuinely different bitmap. Counting those as
     * redundant would overstate the saving on offer, which is the one way this measurement could
     * mislead the decision it exists to inform.
     */
    @Test
    fun aResizeOrThemeFlipIsNotARepeat() {
        val series = listOf(HrPoint(ts = 100, bpm = 60))
        HrTraceSeen.repeat(series, 800, 250, false)
        assertFalse("a resize redraws", HrTraceSeen.repeat(series, 900, 250, false))
        assertFalse("a theme flip redraws", HrTraceSeen.repeat(series, 900, 250, true))
        assertTrue(HrTraceSeen.repeat(series, 900, 250, true))
    }

    /** The newest sample's VALUE changing at the same timestamp still redraws. */
    @Test
    fun aChangedBpmAtTheSameTimestampIsNotARepeat() {
        HrTraceSeen.repeat(listOf(HrPoint(ts = 100, bpm = 60)), 800, 250, false)
        assertFalse(HrTraceSeen.repeat(listOf(HrPoint(ts = 100, bpm = 61)), 800, 250, false))
    }
}
