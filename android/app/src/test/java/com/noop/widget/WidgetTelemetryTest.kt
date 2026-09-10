package com.noop.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Locale

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
        assertTrue(s.render(), "1 sent / 1 admitted / 60 offered" in s.render())
    }

    /** The rate is measured over the steady window, one push a minute being the ordinary cadence. */
    @Test
    fun ratesAreExtrapolatedFromTheSteadyWindow() {
        // One push at t0 opens the warm-up; the rest land a minute apart beyond it.
        WidgetTelemetry.notePushAdmitted(t0)
        for (m in 1..10) {
            WidgetTelemetry.notePushAdmitted(t0 + m * 60_000L)
            WidgetTelemetry.noteRender(bytes = 512 * 1024, elapsedMs = 4)
        }
        val s = WidgetTelemetry.snapshot(t0 + 660_000L)
        // Steady window opens at the first post-warm-up push (t0+60s) and runs 10 minutes; ten pushes
        // and ten draws inside it.
        assertEquals(60.0, s.pushesPerHour!!, 0.001)
        assertEquals(512L, s.meanRenderBytes!! / 1024)
        assertEquals(30.0, s.renderBytesPerHour!! / 1_048_576.0, 0.01)
    }

    /**
     * The startup burst must not be quoted as a rate. The snapshot's fields arrive one by one at
     * launch and each is a key change PushGate admits on the spot, so a launch produces pushes the
     * 60-second clause had nothing to do with. A device reported six pushes in a hundred seconds as
     * 215/h against a steady state of about sixty — the headline number wrong by three and a half
     * times, in the situation where it is looked at first.
     */
    @Test
    fun aStartupBurstIsNotQuotedAsARate() {
        // Six pushes inside the first hundred seconds, as the real capture showed.
        for (ms in listOf(0L, 2_000L, 5_000L, 9_000L, 30_000L, 95_000L)) {
            WidgetTelemetry.notePushAdmitted(t0 + ms)
        }
        val s = WidgetTelemetry.snapshot(t0 + 100_000L)
        assertEquals(6, s.pushesAdmitted)
        assertNull("a burst is not a rate", s.pushesPerHour)
        val line = s.render()
        assertTrue(line, "6 sent / 6 admitted" in line)
        assertTrue("the line must say the rate is withheld: $line", "steady" in line)
    }

    /**
     * A rate computed from a few seconds of uptime is noise wearing a number's clothes, and this line
     * goes in front of someone deciding whether to change the refresh cadence.
     */
    @Test
    fun noRateIsClaimedUnderASteadyWindow() {
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
        assertFalse("the first draw is never a repeat", HrTraceSeen.repeat("w1", series, 800, 250, false))
        assertTrue(HrTraceSeen.repeat("w1", series, 800, 250, false))
        assertTrue(HrTraceSeen.repeat("w1", series, 800, 250, false))
    }

    /** A new bucket is a different picture. */
    @Test
    fun anAdvancedSeriesIsNotARepeat() {
        val series = listOf(HrPoint(ts = 100, bpm = 60))
        HrTraceSeen.repeat("w1", series, 800, 250, false)
        assertFalse(HrTraceSeen.repeat("w1", series + HrPoint(ts = 160, bpm = 62), 800, 250, false))
    }

    /**
     * Same points, different box or theme, is a genuinely different bitmap. Counting those as
     * redundant would overstate the saving on offer, which is the one way this measurement could
     * mislead the decision it exists to inform.
     */
    @Test
    fun aResizeOrThemeFlipIsNotARepeat() {
        val series = listOf(HrPoint(ts = 100, bpm = 60))
        HrTraceSeen.repeat("w1", series, 800, 250, false)
        assertFalse("a resize redraws", HrTraceSeen.repeat("w1", series, 900, 250, false))
        assertFalse("a theme flip redraws", HrTraceSeen.repeat("w1", series, 900, 250, true))
        assertTrue(HrTraceSeen.repeat("w1", series, 900, 250, true))
    }

    /** The newest sample's VALUE changing at the same timestamp still redraws. */
    @Test
    fun aChangedBpmAtTheSameTimestampIsNotARepeat() {
        HrTraceSeen.repeat("w1", listOf(HrPoint(ts = 100, bpm = 60)), 800, 250, false)
        assertFalse(HrTraceSeen.repeat("w1", listOf(HrPoint(ts = 100, bpm = 61)), 800, 250, false))
    }

    /**
     * Two placed HR widgets must not answer for each other. A single shared slot made each widget's
     * necessary FIRST draw look like a repeat of the other's, inflating the redundancy count - and an
     * inflated count argues for an optimisation that is not actually on offer, which is the one
     * direction this measurement must not be wrong in.
     */
    @Test
    fun twoPlacedWidgetsDoNotAnswerForEachOther() {
        val series = listOf(HrPoint(ts = 100, bpm = 60))
        assertFalse("w1's first draw", HrTraceSeen.repeat("w1", series, 800, 250, false))
        assertFalse("w2's first draw is its own, not a repeat of w1's",
            HrTraceSeen.repeat("w2", series, 800, 250, false))
        // Each still recognises its OWN repeat.
        assertTrue(HrTraceSeen.repeat("w1", series, 800, 250, false))
        assertTrue(HrTraceSeen.repeat("w2", series, 800, 250, false))
        // And an advance on one does not clear the other.
        val grown = series + HrPoint(ts = 160, bpm = 62)
        assertFalse(HrTraceSeen.repeat("w1", grown, 800, 250, false))
        assertTrue(HrTraceSeen.repeat("w2", series, 800, 250, false))
    }

    /**
     * A widget composes from saved prefs when it is placed, or after a process start, with no push
     * involved. Reporting "no pushes" there is true and drops the draw counts, which are the
     * expensive half and the whole reason this exists.
     */
    @Test
    fun drawsWithNoPushesAreStillReported() {
        WidgetTelemetry.noteRender(bytes = 512 * 1024, elapsedMs = 5)
        WidgetTelemetry.noteRender(bytes = 512 * 1024, elapsedMs = 5)
        val line = WidgetTelemetry.snapshot(t0 + 120_000L).render()
        assertTrue("must not claim an empty session: $line", "no pushes this app session" !in line)
        assertTrue(line, "no pushes" in line)
        assertTrue(line, "2 trace draws" in line)
        assertTrue(line, "mean 512KB" in line)
    }

    /**
     * The rate is a diagnostics field read by eye and by grep. Under a locale whose decimal separator
     * is a comma, an unqualified format would print "30,0MB/h" and put a field separator inside a
     * number.
     */
    @Test
    fun ratesFormatWithADotWhateverTheDefaultLocale() {
        val original = Locale.getDefault()
        try {
            Locale.setDefault(Locale.GERMANY)
            WidgetTelemetry.notePushAdmitted(t0)
            for (m in 1..10) {
                WidgetTelemetry.notePushAdmitted(t0 + m * 60_000L)
                WidgetTelemetry.noteRender(bytes = 512 * 1024, elapsedMs = 4)
            }
            val line = WidgetTelemetry.snapshot(t0 + 660_000L).render()
            assertTrue(line, "60.0/h" in line)
            assertTrue(line, "30.0MB/h" in line)
            assertFalse(line, "," in line.substringAfter("Widgets:"))
        } finally {
            Locale.setDefault(original)
        }
    }

    /**
     * The effective width headroom, which is NOT [HrTrace.WIDTH_HEADROOM]: the byte budget runs out
     * first at any realistic widget size. Pinned because the constant reads like the guarantee and is
     * not, and because the value below 1.0 is the case where the bitmap is UPSCALED — the artefact the
     * headroom exists to prevent. If a change to the budget or the chart height moves these, that is
     * worth seeing rather than discovering from a soft stroke on someone's home screen.
     */
    @Test
    fun theByteBudgetBindsBeforeTheWidthHeadroomDoes() {
        fun effective(densityDpi: Float, widthDp: Float): Double {
            val density = densityDpi / 160f
            val chartDp = (widthDp - 28f - 34f).coerceAtLeast(24f)
            val req = (chartDp * density).toInt()
            val h = (92f * density).toInt()
            return HrTrace.widestAtHeight(req, h).toDouble() / req
        }
        // The property, not a pinned number: at every realistic size the BUDGET is what caps the width,
        // so the nominal headroom is never reached and raising it would change nothing.
        for (dpi in listOf(420f, 480f)) {
            for (dp in listOf(300f, 340f, 380f)) {
                val eff = effective(dpi, dp)
                assertTrue(
                    "$dpi/$dp reached $eff, so the byte budget was not the binding constraint",
                    eff < HrTrace.WIDTH_HEADROOM,
                )
            }
        }
        // The case that matters: a wide card at high density is drawn NARROWER than it is displayed,
        // so the bitmap is UPSCALED — precisely the artefact the headroom exists to prevent.
        assertTrue("480dpi/380dp should be upscaled", effective(480f, 380f) < 1.0)
        // And a small card is where the intent survives best, though still short of the nominal 2x.
        assertTrue("420dpi/300dp should have the most headroom", effective(420f, 300f) > 1.5)
    }

    /**
     * The withheld-rate message has to name the window it is actually waiting on. Phrasing it as a
     * minimum UPTIME was wrong: pushes can be sparse enough that the steady window opens late, so the
     * line would sit twenty minutes in still claiming it needed six, which reads as broken rather than
     * explained.
     */
    @Test
    fun aWithheldRateNamesTheSteadyWindowNotTheUptime() {
        WidgetTelemetry.notePushAdmitted(t0)                    // opens warm-up
        WidgetTelemetry.notePushAdmitted(t0 + 19 * 60_000L)     // opens steady, nineteen minutes in
        val line = WidgetTelemetry.snapshot(t0 + 20 * 60_000L).render()
        assertNull(WidgetTelemetry.snapshot(t0 + 20 * 60_000L).pushesPerHour)
        assertTrue("uptime should read twenty minutes: $line", "over 20m" in line)
        assertTrue("and the wait should be stated against the steady window: $line",
            "steady 1m of 5m" in line)
    }

    /**
     * The rate has to be blind to nothing except what never reached a widget. A push RenderedGate
     * declines is admitted and then dropped, so counting it here would have made this figure unable
     * to fall when the gate fired — and lowering it is the gate's entire purpose. An instrument that
     * cannot show the effect of the optimisation shipped beside it is measuring the wrong thing.
     */
    @Test
    fun declinedPushesAreNotCountedAsSentOrRated() {
        WidgetTelemetry.notePushAdmitted(t0)                       // warm-up
        for (m in 1..10) {
            WidgetTelemetry.notePushAdmitted(t0 + m * 60_000L)
            if (m > 5) WidgetTelemetry.notePushUnchanged()          // five of the ten never went out
        }
        val s = WidgetTelemetry.snapshot(t0 + 660_000L)
        assertEquals(11, s.pushesAdmitted)
        assertEquals(6, s.pushesSent)                              // 11 admitted - 5 declined
        // Steady window holds ten pushes over ten minutes, five of them declined: five sends an hour
        // at that cadence would be 30/h, not the 60/h the admitted count alone would have claimed.
        assertEquals(30.0, s.pushesPerHour!!, 0.001)
        val line = s.render()
        assertTrue(line, "6 sent / 11 admitted" in line)
        assertTrue(line, "5 unchanged" in line)
    }

    /**
     * The widget-removed capture is half of the comparison that answers whether the widget costs
     * anything, so a push with nowhere to go must not read as a send. Left as one, both halves of the
     * A/B would have shown identical sent counts and rates, and only the draw count would have
     * differed — which is a much weaker signal than the one the counters are supposed to give.
     */
    @Test
    fun aPushWithNoWidgetPlacedIsNotASend() {
        WidgetTelemetry.notePushAdmitted(t0)                       // warm-up
        for (m in 1..10) {
            WidgetTelemetry.notePushAdmitted(t0 + m * 60_000L)
            WidgetTelemetry.notePushNoWidget()
        }
        val s = WidgetTelemetry.snapshot(t0 + 660_000L)
        assertEquals(11, s.pushesAdmitted)
        assertEquals(1, s.pushesSent)                              // only the warm-up push had a widget
        assertEquals(0.0, s.pushesPerHour!!, 0.001)                // nothing was sent in the window
        val line = s.render()
        assertTrue(line, "1 sent / 11 admitted" in line)
        assertTrue(line, "10 with no widget placed" in line)
    }

    /**
     * The two non-send outcomes are different answers and must not be conflated: "nothing new to
     * show" is the rendered gate doing its job, "nobody to show it to" is the widget being absent.
     */
    @Test
    fun theTwoNonSendOutcomesAreReportedApart() {
        WidgetTelemetry.notePushAdmitted(t0)
        for (m in 1..10) WidgetTelemetry.notePushAdmitted(t0 + m * 60_000L)
        repeat(3) { WidgetTelemetry.notePushUnchanged() }
        repeat(2) { WidgetTelemetry.notePushNoWidget() }
        val s = WidgetTelemetry.snapshot(t0 + 660_000L)
        assertEquals(6, s.pushesSent)                              // 11 - 3 - 2
        val line = s.render()
        assertTrue(line, "3 unchanged" in line)
        assertTrue(line, "2 with no widget placed" in line)
    }
}
