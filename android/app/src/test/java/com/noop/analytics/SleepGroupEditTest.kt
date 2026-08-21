package com.noop.analytics

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1492: correcting a night's bed/wake times saved successfully and changed nothing on screen.
 *
 * A night the strap split into fragments displays as one bridged group — the header's bedtime is the FIRST
 * fragment's onset and its wake is the group's LATEST end. The editor was anchored to the single winning
 * fragment, which on a split night is usually neither. Shortening a night "detected too long" narrowed an
 * interior block while both fragments defining the displayed ends stayed put.
 *
 * These pin the semantics of applying the drawn window across the whole night.
 */
class SleepGroupEditTest {

    private val h = 3_600L
    private val t0 = 1_780_000_000L

    private fun frag(startTs: Long, endTs: Long, deviceId: String = "my-whoop") = SleepSession(
        deviceId = deviceId, startTs = startTs, endTs = endTs,
    )

    /** A night split into three, spanning t0 → t0+10h — the shape that reads as "detected too long". */
    private fun splitNight() = listOf(
        frag(t0, t0 + 2 * h),
        frag(t0 + 3 * h, t0 + 5 * h),
        frag(t0 + 8 * h, t0 + 10 * h),
    )

    private fun window(p: SleepGroupEdit.Plan) =
        p.clipped.minOf { it.effectiveStartTs } to p.clipped.maxOf { it.endTs }

    /**
     * The regression: the drawn window becomes the night's window. Before, the edit landed on one fragment
     * and the displayed first-onset / latest-end were untouched.
     */
    @Test fun theDrawnWindowBecomesTheNightsWindow() {
        val plan = SleepGroupEdit.plan(splitNight(), t0 + 1 * h, t0 + 6 * h)
        assertEquals((t0 + 1 * h) to (t0 + 6 * h), window(plan))
    }

    /**
     * ...which requires retiring the fragment that fell outside. Leaving it in place is precisely what kept
     * the night long: it would go on defining the group's latest wake.
     */
    @Test fun aFragmentOutsideTheWindowIsDroppedNotLeftBehind() {
        val plan = SleepGroupEdit.plan(splitNight(), t0 + 1 * h, t0 + 6 * h)
        assertEquals(1, plan.dropped.size)
        assertEquals(t0 + 8 * h, plan.dropped[0].startTs)   // the 8h–10h tail
        assertEquals(2, plan.clipped.size)
    }

    /** An interior fragment only ever narrows — it must not be stretched out to the drawn bounds. */
    @Test fun interiorFragmentsAreNarrowedNotStretched() {
        val plan = SleepGroupEdit.plan(splitNight(), t0 - 1 * h, t0 + 11 * h)
        val interior = plan.clipped[1]
        assertEquals(t0 + 3 * h, interior.effectiveStartTs)
        assertEquals(t0 + 5 * h, interior.endTs)
    }

    /**
     * The edit must LENGTHEN a night the strap cut short too, not only shorten a long one — the outer
     * fragments take the drawn bounds outright rather than intersecting with what was detected.
     */
    @Test fun theWindowCanExtendBeyondWhatWasDetected() {
        val plan = SleepGroupEdit.plan(splitNight(), t0 - 1 * h, t0 + 11 * h)
        assertEquals((t0 - 1 * h) to (t0 + 11 * h), window(plan))
        assertTrue(plan.dropped.isEmpty())
    }

    /**
     * A one-fragment night must come out exactly as the single-row edit would leave it, so the unfragmented
     * path keeps its long-standing behaviour through this code rather than beside it.
     */
    @Test fun aSingleFragmentReproducesTheSingleRowEdit() {
        val only = frag(t0, t0 + 8 * h)
        val plan = SleepGroupEdit.plan(listOf(only), t0 + 1 * h, t0 + 7 * h)
        assertEquals(1, plan.clipped.size)
        assertTrue(plan.dropped.isEmpty())
        assertEquals(t0 + 1 * h, plan.clipped[0].effectiveStartTs)
        assertEquals(t0 + 7 * h, plan.clipped[0].endTs)
        assertTrue(plan.clipped[0].userEdited)
        // The detected key never moves — the correction rides in startTsAdjusted.
        assertEquals(only.startTs, plan.clipped[0].startTs)
    }

    /**
     * A window that clears the whole night is refused outright. A bed/wake correction should never be read
     * as "delete this night", and the editor's own confirm gate exists to catch a disjoint window first.
     */
    @Test fun aWindowMissingTheNightEntirelyChangesNothing() {
        val plan = SleepGroupEdit.plan(splitNight(), t0 + 20 * h, t0 + 22 * h)
        assertTrue(plan.clipped.isEmpty())
        assertTrue(plan.dropped.isEmpty())
    }

    /** An inverted window is refused rather than persisted as a phantom night. */
    @Test fun anInvertedWindowIsRefused() {
        val plan = SleepGroupEdit.plan(splitNight(), t0 + 6 * h, t0 + 1 * h)
        assertTrue(plan.clipped.isEmpty())
    }

    /**
     * The coverage window the editor seeds and validates against spans the WHOLE night. Testing against the
     * winning fragment alone is what let an ordinary edit read as disjoint and get diverted into a confirm.
     */
    @Test fun theGroupWindowSpansEveryFragment() {
        assertEquals(t0 to (t0 + 10 * h), SleepGroupEdit.groupWindow(splitNight()))
        assertNull(SleepGroupEdit.groupWindow(emptyList()))
    }
}
