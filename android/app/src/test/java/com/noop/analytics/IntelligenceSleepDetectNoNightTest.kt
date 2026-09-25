package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the "HR tracked but no sleep" diagnostic (#1244). When a day clears the >=200-HR gate yet the
 * stager detects NO in-bed session, the summary line only says `totalSleepMin=nil` with no clue why —
 * every other night trace (`rhr`/`rrsample`/`hrv diag`) emits only once a session exists. The engine now
 * ships one counts-only reason line naming the raw inputs the stager was handed, so the next capture
 * separates the causes (no motion vs coverage gap vs window). `sleepDetectNoNightLogLine` is the pure
 * formatter the loop calls; tested directly. Mirrors the Swift `IntelligenceSleepDetectNoNightTests`
 * so the two platforms log a byte-identical line.
 */
class IntelligenceSleepDetectNoNightTest {

    @Test
    fun noMotionNight_theLeadingHypothesis() {
        // The #1244 shape: plenty of HR, but grav=0 (no motion offloaded) so the in-bed detector can't
        // gate the night → nothing stages. window=54h is the past-day span (30 h back → next midnight).
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-08-11", hrCount = 41230, rrCount = 0, respCount = 880,
            gravCount = 0, stepCount = 12, providedCount = 0, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null, windowHours = 54, skinCount = 0,
        )
        assertEquals(
            // reason=no-motion with provided=0: no gravity AND the HR-only spine (#1801) yielded
            // nothing either. The bare reason is only correct because nothing was provided; see
            // noMotionButSessionsWereProvided for the case where it is not.
            "sleep-detect day=2026-08-11 NO-NIGHT hr=41230 rr=0 resp=880 " +
                "grav=0 skin=0 steps=12 provided=0 window=54h reason=no-motion",
            line,
        )
    }

    /**
     * The case a 5/MG overnight capture actually hits, and the one no fixture covered.
     *
     * Since #1801 a no-gravity day still runs the HR-only spine. On that capture it kept four sessions,
     * the longest 311 minutes, and handed them over, and this line still said `no-motion`, which reads as
     * "nothing could stage a night" while the log above showed something had. With sessions provided and
     * the night still empty, the question is what dropped them, not what the strap can do.
     *
     * The fixture asserts on PROVIDED sessions, not on their source: with no gravity they may be the
     * HR-only spine's output or a stored hypnogram, and the line cannot tell. Claiming otherwise would be
     * the same over-claim this split removes.
     */
    @Test
    fun noMotionButSessionsWereProvided() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-21", hrCount = 106144, rrCount = 73959, respCount = 0,
            gravCount = 0, stepCount = 0, providedCount = 3, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null, windowHours = 30, skinCount = 0,
        )
        // EXACT match on the parsed token, not `contains`. `no-motion` is a PREFIX of
        // `no-motion-provided-unused`, so a contains check matches both and cannot catch a regression to
        // the bare value. The first version used `contains("reason=no-motion ")` with a trailing space,
        // which is false for BOTH values whenever nothing is at its read cap, so it could never fail.
        assertEquals(line, "no-motion-provided-unused", reasonToken(line))
    }

    /** No gravity AND nothing provided keeps the plain reason: HR alone yielded nothing either. */
    @Test
    fun noMotionAndNothingProvidedKeepsThePlainReason() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-21", hrCount = 106144, rrCount = 73959, respCount = 0,
            gravCount = 0, stepCount = 0, providedCount = 0, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null, windowHours = 30, skinCount = 0,
        )
        assertEquals(line, "no-motion", reasonToken(line))
    }

    /**
     * The capture this was built for, in one line.
     *
     * A 5/MG overnight: no gravity, the HR-only spine kept three sessions with a 240-minute longest, and
     * the night came out empty. `provided=3` said sessions went in; nothing said where they fell. Since
     * a session belongs to the day its END lands on, `providedHere=0` is the whole diagnosis, and
     * `providedLongestEnd` names the neighbour that absorbed the one that should have matched.
     */
    @Test
    fun `provided sessions that end on another day are named`() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-26", hrCount = 136154, rrCount = 112882, respCount = 0,
            gravCount = 0, stepCount = 0, providedCount = 3, providedEndingOnDay = 0,
            providedLongestMin = 240, providedLongestEndDay = "2026-09-25",
            windowHours = 39, skinCount = 0,
        )
        assertEquals(
            "sleep-detect day=2026-09-26 NO-NIGHT hr=136154 rr=112882 resp=0 " +
                "grav=0 skin=0 steps=0 provided=3 providedHere=0 providedLongest=240 " +
                "providedLongestEnd=2026-09-25 window=39h reason=no-motion-provided-unused",
            line,
        )
    }

    /**
     * With nothing provided the three fields say nothing `reason=no-motion` has not, so they stay off.
     * Same rule the sibling `atCap` note follows: a suffix appears only when it carries information.
     */
    @Test
    fun `nothing provided means no provided fields at all`() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-26", hrCount = 1000, rrCount = 0, respCount = 0,
            gravCount = 0, stepCount = 0, providedCount = 0, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null,
            windowHours = 39, skinCount = 0,
        )
        assertFalse(line, line.contains("providedHere"))
        assertFalse(line, line.contains("providedLongest"))
    }

    /**
     * A night that DID build from its provided sessions reads the other way round, so a reader can tell
     * "none of them were mine" from "some were mine and the night still came out empty". The second is a
     * different bug and must not render identically to the first.
     */
    @Test
    fun `provided sessions ending here are counted`() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-26", hrCount = 136154, rrCount = 112882, respCount = 0,
            gravCount = 0, stepCount = 0, providedCount = 3, providedEndingOnDay = 2,
            providedLongestMin = 240, providedLongestEndDay = "2026-09-26",
            windowHours = 39, skinCount = 0,
        )
        assertTrue(line, line.contains(" providedHere=2 "))
        assertTrue(line, line.contains(" providedLongestEnd=2026-09-26 "))
    }

    /**
     * Missing values render `nil`, never 0 or an empty token. A provided session whose span could not be
     * measured is a different fact from one that lasted no time, and this line is read as evidence.
     */
    @Test
    fun `absent longest renders nil not zero`() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-26", hrCount = 1, rrCount = 1, respCount = 0,
            gravCount = 0, stepCount = 0, providedCount = 2, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null,
            windowHours = 39, skinCount = 0,
        )
        assertTrue(line, line.contains(" providedLongest=nil providedLongestEnd=nil "))
    }

    // ---- which provided session gets reported ----

    private fun session(startMin: Long, endMin: Long) =
        DetectedSleep(startMin * 60L, endMin * 60L, 0.9, emptyList(), null, null)

    /** The plain case: the longest wins. */
    @Test
    fun `the longest provided session is the one reported`() {
        val picked = IntelligenceEngine.longestProvidedForDiag(
            listOf(session(0, 60), session(100, 340), session(400, 430)),
        )
        assertEquals(240L, ((picked!!.end - picked.start) / 60L))
    }

    /**
     * The tie, which is why this is a named function rather than a `maxByOrNull` at the call site.
     *
     * Kotlin's `maxByOrNull` keeps the FIRST of two equal elements and Swift's `max(by:)` does not agree,
     * while the field actually printed is the END day. Two equal-length sessions ending on different days
     * would then render differently on the two platforms from identical input. Ordering by
     * (duration, end) makes the reported end the later one on both.
     *
     * Not a corner case: the HR-only spine works in fixed epochs, so durations are quantised and repeat.
     */
    @Test
    fun `equal length sessions report the later ending one`() {
        val early = session(0, 240)
        val late = session(600, 840)
        assertEquals(late.end, IntelligenceEngine.longestProvidedForDiag(listOf(early, late))!!.end)
        // Order of the input must not change the answer, which is the whole property.
        assertEquals(late.end, IntelligenceEngine.longestProvidedForDiag(listOf(late, early))!!.end)
    }

    /** Nothing provided, nothing picked. */
    @Test
    fun `no sessions yields null`() {
        assertEquals(null, IntelligenceEngine.longestProvidedForDiag(emptyList()))
    }

    /** Motion present still outranks everything: the inputs were there and staging produced nothing. */
    @Test
    fun motionPresentStaysStagedNoneEvenWithProvidedSessions() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-21", hrCount = 5000, rrCount = 900, respCount = 300,
            gravCount = 4, stepCount = 0, providedCount = 3, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null, windowHours = 48, skinCount = 0,
        )
        assertEquals(line, "staged-none", reasonToken(line))
    }

    @Test
    fun todayWindowIs48h() {
        // Today's read caps at dayStart+18h (vs a past day's next-midnight), so the whole span is 48 h.
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-08-12", hrCount = 5000, rrCount = 900, respCount = 300,
            gravCount = 4, stepCount = 0, providedCount = 0, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null, windowHours = 48, skinCount = 0,
        )
        assertTrue(line, line.contains("window=48h"))
        // The other branch: motion WAS present and staging still produced nothing, which is the case
        // worth investigating rather than a capability limit.
        assertEquals(line, "staged-none", reasonToken(line))
    }

    @Test
    fun lineCarriesNoEmDash() {
        // House style: never an em-dash in shared text.
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-08-11", hrCount = 1, rrCount = 1, respCount = 1,
            gravCount = 1, stepCount = 1, providedCount = 1, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null, windowHours = 54, skinCount = 1,
        )
        assertFalse(line.contains("—"))
    }

    /**
     * The signal this line was missing. Gravity is a PLAIN read with no truncation counter, so a night
     * clipped of its newest motion staged badly and said nothing about why - and `grav=192698` reads as
     * healthy until you know it is 96% of a cap. A read that comes back AT the limit is truncated, which
     * is what `full.count >= limit` means everywhere else here.
     */
    @Test fun `a stream at its read cap is named`() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-06", hrCount = 1000, rrCount = 1000, respCount = 0,
            gravCount = StreamReadCap.GRAVITY, stepCount = 0, providedCount = 0, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null, windowHours = 54, skinCount = 0,
        )
        assertTrue(line, line.contains("atCap=grav"))
    }

    /**
     * HR and R-R at their caps produce NO marker, and that is deliberate rather than an oversight.
     *
     * Both arrive through `SlidingStreamWindow.rows`, which returns a SLICE of a read spanning more than
     * this night, so a truncated spliced window still hands back a count under the cap - the marker would
     * miss the very case it claims to catch. Their exact truncation count is printed once per pass by
     * `WindowedStreamPlan.logLine` instead. Pinned so the omission is not "fixed" back in.
     */
    @Test fun `hr and rr at their caps carry no marker`() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-06", hrCount = StreamReadCap.HR, rrCount = StreamReadCap.RR, respCount = 0,
            gravCount = 10, stepCount = 0, providedCount = 0, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null, windowHours = 54, skinCount = 0,
        )
        assertFalse(line, line.contains("atCap"))
    }

    /** A healthy night says nothing extra - the marker only appears when something actually clipped. */
    @Test fun `a night under the caps carries no marker`() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-06", hrCount = 192_698, rrCount = 136_285, respCount = 0,
            gravCount = 192_698, stepCount = 0, providedCount = 0, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null, windowHours = 54, skinCount = 0,
        )
        assertFalse(line, line.contains("atCap"))
    }

    /**
     * The field capture that motivated the caps: 192,698 gravity rows was 96% of the OLD 200,000 limit
     * and silent. Under the caps this ships with, the same night is comfortably clear - so a marker
     * appearing now means a genuinely denser night, not the old ceiling.
     */
    @Test fun `the measured field night is clear of the caps`() {
        assertTrue(192_698 < StreamReadCap.GRAVITY)
    }

    /**
     * The count that could not be measured. Skin temp only appears in a Test Centre "Night" line, which
     * fires when a session EXISTS - so on the nights being triaged, the ones with no sleep at all, its
     * volume was invisible. It rides in the record that carries gravity, so whether it is dense or sparse
     * decides whether its own 21-day anchor scan is anywhere near a cap; nobody could say which.
     */
    @Test fun `the line reports the skin sample count`() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-06", hrCount = 1000, rrCount = 900, respCount = 0, gravCount = 0,
            stepCount = 0, providedCount = 0, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null, windowHours = 54, skinCount = 4242,
        )
        assertTrue(line, line.contains("skin=4242"))
    }

    /**
     * Skin is the stream whose density was never measured, and it was the one `atCap` did not cover
     * when the marker was first written — so a clipped skin read printed a bare count and no warning.
     */
    @Test fun `skin at its read cap is named`() {
        val line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day = "2026-09-06", hrCount = 10, rrCount = 10, respCount = 0, gravCount = 10,
            stepCount = 0, providedCount = 0, providedEndingOnDay = 0,
            providedLongestMin = null, providedLongestEndDay = null, windowHours = 54, skinCount = StreamReadCap.SKIN,
        )
        assertTrue(line, line.contains("atCap=skin"))
    }

    /**
     * The `reason=` value alone, stopping at the space before any `atCap=` marker.
     *
     * Comparing the whole line with `contains` cannot separate `no-motion` from
     * `no-motion-provided-unused`, since the first is a prefix of the second.
     */
    private fun reasonToken(line: String): String =
        line.substringAfter("reason=", "").substringBefore(' ')
}
