package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the hypnogram scrub (#1855): dragging the FILLED hypnogram reports the real clock time and
 * the stage under the finger.
 *
 * The component matters as much as the maths here. `FilledHypnogram` draws persisted per-epoch
 * segments positioned by `xOf(sec) = w * (sec / spanSec)` — linear in real time — so inverting x
 * yields a timestamp the night actually had. The PROPORTIONAL strip is a different thing: it
 * arranges stage TOTALS in a fixed light/deep/light/rem/light/awake order that is not the
 * chronology, so a clock time read off that would be invented. These tests pin the honest one.
 */
class HypnogramScrubTest {

    private val origin = 1_700_000_000.0          // unix seconds
    private val span = 8 * 3600.0                 // an 8-hour window

    /** deep 0–2h, rem 2–3h, then a deliberate unlabelled gap 3–4h, light 4–8h. */
    private val intervals = listOf(
        StageInterval("deep", 0.0, 2 * 3600.0),
        StageInterval("rem", 2 * 3600.0, 3 * 3600.0),
        StageInterval("light", 4 * 3600.0, 8 * 3600.0),
    )

    @Test fun timeIsTheRealClockTimeAtThatFractionOfTheNight() {
        val hit = scrubHitAt(xPx = 100f, widthPx = 400f, intervals, origin, span)!!
        assertEquals((origin + 2 * 3600.0).toLong(), hit.timestamp)   // a quarter in = 2 h
    }

    @Test fun theStageComesFromContainmentOnRealIntervals() {
        assertEquals("deep", scrubHitAt(50f, 400f, intervals, origin, span)!!.stage)
        assertEquals("rem", scrubHitAt(125f, 400f, intervals, origin, span)!!.stage)
        assertEquals("light", scrubHitAt(300f, 400f, intervals, origin, span)!!.stage)
    }

    @Test fun anUnlabelledGapReportsNoStageRatherThanBorrowingANeighbour() {
        // 3.5 h in lands in the gap the stager left unlabelled. The time is still real, but naming a
        // stage there would be asserting something the night never recorded.
        val hit = scrubHitAt(xPx = 175f, widthPx = 400f, intervals, origin, span)!!
        assertEquals("", hit.stage)
        assertEquals((origin + 3.5 * 3600.0).toLong(), hit.timestamp)
    }

    @Test fun theEndsClampToTheWindow() {
        assertEquals(origin.toLong(), scrubHitAt(0f, 400f, intervals, origin, span)!!.timestamp)
        assertEquals((origin + span).toLong(), scrubHitAt(400f, 400f, intervals, origin, span)!!.timestamp)
    }

    @Test fun pastEitherEdgeClampsRatherThanExtrapolating() {
        assertEquals(origin.toLong(), scrubHitAt(-99f, 400f, intervals, origin, span)!!.timestamp)
        assertEquals((origin + span).toLong(), scrubHitAt(9999f, 400f, intervals, origin, span)!!.timestamp)
    }

    @Test fun degenerateInputsReportNothingRatherThanGuessing() {
        assertNull("no width", scrubHitAt(10f, 0f, intervals, origin, span))
        assertNull("no span", scrubHitAt(10f, 400f, intervals, origin, 0.0))
        assertNull("no intervals", scrubHitAt(10f, 400f, emptyList(), origin, span))
    }
}
