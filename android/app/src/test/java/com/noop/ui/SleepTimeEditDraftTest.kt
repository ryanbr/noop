package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

class SleepTimeEditDraftTest {
    private val zone = ZoneId.of("UTC")

    private fun ts(y: Int, mo: Int, d: Int, h: Int, mi: Int): Long =
        LocalDateTime.of(y, mo, d, h, mi).atZone(zone).toEpochSecond()

    @Test
    fun splitNightCorrectionSavesOneFinalWindow() {
        val original = SleepTimeEditDraft(
            startTs = ts(2026, 7, 16, 0, 3),
            endTs = ts(2026, 7, 16, 1, 30),
        )

        val finalDraft = original
            .withBedCandidate(
                candidateBedTs = ts(2026, 7, 16, 0, 0),
                nowTs = ts(2026, 7, 16, 8, 0),
                zone = zone,
            )
            .withWakeCandidate(ts(2026, 7, 16, 7, 0))

        assertEquals(
            ts(2026, 7, 16, 0, 0) to ts(2026, 7, 16, 7, 0),
            finalDraft.validatedWindow(nowTs = ts(2026, 7, 16, 8, 0)),
        )
    }

    /**
     * #2470: a bedtime candidate that already carries the next-day date survives into a valid window.
     *
     * Honest about what this does and does not prove. `withBedCandidate` was never the bug: it accepted a
     * correctly dated candidate before #2470 was fixed and still does, and this case passes on an unfixed
     * tree. It is kept because the property is worth pinning, not as the regression test.
     *
     * The bug was that the dialog never produced such a candidate, because it replaced only hour and
     * minute on the detected start. That arithmetic now lives in `sleepEndpointTs`, tested below.
     */
    @Test
    fun eveningBedtimeCandidateWithWakeDayDateStaysValid() {
        val original = SleepTimeEditDraft(
            startTs = ts(2026, 9, 24, 23, 0),
            endTs = ts(2026, 9, 25, 8, 0),
        )

        val corrected = original.withBedCandidate(
            candidateBedTs = ts(2026, 9, 25, 4, 0),
            nowTs = ts(2026, 9, 25, 12, 0),
            zone = zone,
        )

        assertEquals(ts(2026, 9, 25, 4, 0), corrected.startTs)
        assertEquals(
            ts(2026, 9, 25, 4, 0) to ts(2026, 9, 25, 8, 0),
            corrected.validatedWindow(nowTs = ts(2026, 9, 25, 12, 0)),
        )
    }

    // ---- the arithmetic #2470 got wrong ----

    /**
     * The #2470 shape: a 23:00 onset corrected to 04:00 on the WAKE day.
     *
     * The old dialog replaced only hour and minute on the detected start, so this produced 04:00 on day 1
     * and a 28-hour draft that the 24-hour edit limit rejected, surfacing as a Save button that silently
     * would not work. Taking the selected date is the fix, and this is the arithmetic that does it.
     */
    @Test
    fun endpointTakesTheSelectedDateNotTheBaseDate() {
        val detectedStart = ts(2026, 9, 24, 23, 0)
        val corrected = sleepEndpointTs(
            baseTs = detectedStart, year = 2026, month = 8, dayOfMonth = 25, hour = 4, minute = 0,
            timeZone = java.util.TimeZone.getTimeZone(zone),
        )
        assertEquals(ts(2026, 9, 25, 4, 0), corrected)
        // The failure it replaces: keeping the base date would land a day earlier.
        assertNotEquals(ts(2026, 9, 24, 4, 0), corrected)
    }

    /** Picking the same calendar day the endpoint already had is a plain time change. */
    @Test
    fun endpointOnTheSameDayIsJustATimeChange() {
        val base = ts(2026, 9, 25, 8, 0)
        assertEquals(
            ts(2026, 9, 25, 6, 30),
            sleepEndpointTs(
                baseTs = base, year = 2026, month = 8, dayOfMonth = 25, hour = 6, minute = 30,
                timeZone = java.util.TimeZone.getTimeZone(zone),
            ),
        )
    }

    /**
     * Seconds and milliseconds are zeroed. Two edits that pick the same minute must produce the same
     * timestamp, because the draft's equality and the 24-hour guard both compare on it.
     */
    @Test
    fun endpointZeroesSecondsAndMillis() {
        val baseWithSeconds = ts(2026, 9, 25, 8, 0) + 37
        val out = sleepEndpointTs(
            baseTs = baseWithSeconds, year = 2026, month = 8, dayOfMonth = 25, hour = 8, minute = 0,
            timeZone = java.util.TimeZone.getTimeZone(zone),
        )
        assertEquals(ts(2026, 9, 25, 8, 0), out)
        assertEquals(0L, out % 60L)
    }

    @Test
    fun explicitWakeDateIsPreservedAfterBedCorrection() {
        val original = SleepTimeEditDraft(
            startTs = ts(2026, 7, 16, 1, 6),
            endTs = ts(2026, 7, 16, 5, 0),
        )

        val finalDraft = original
            .withBedCandidate(
                candidateBedTs = ts(2026, 7, 16, 23, 0),
                nowTs = ts(2026, 7, 16, 8, 0),
                zone = zone,
            )
            .withWakeCandidate(ts(2026, 7, 18, 7, 0))

        assertEquals(ts(2026, 7, 15, 23, 0), finalDraft.startTs)
        assertEquals(ts(2026, 7, 18, 7, 0), finalDraft.endTs)
        assertNull(finalDraft.validatedWindow(nowTs = ts(2026, 7, 18, 8, 0)))
    }

    @Test
    fun explicitWakeBeforeBedRemainsInvalid() {
        val draft = SleepTimeEditDraft(
            startTs = ts(2026, 7, 16, 23, 0),
            endTs = ts(2026, 7, 17, 5, 0),
        ).withWakeCandidate(ts(2026, 7, 16, 22, 30))

        assertEquals(ts(2026, 7, 16, 22, 30), draft.endTs)
        assertNull(draft.validatedWindow(nowTs = ts(2026, 7, 17, 8, 0)))
    }

    @Test
    fun invalidIntermediateWindowCannotBeSaved() {
        val draft = SleepTimeEditDraft(
            startTs = ts(2026, 7, 16, 6, 0),
            endTs = ts(2026, 7, 16, 5, 0),
        )

        assertNull(draft.validatedWindow(nowTs = ts(2026, 7, 16, 8, 0)))
    }
}
