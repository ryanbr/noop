package com.noop.ble

import com.noop.data.InsertCounts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the success-side observability the log forensics flagged as the blind spot (#150): NOOP logged
 * FAILURES (decoded-to-0) but never SUCCESSES, so a strap log couldn't tell a banking strap from a
 * broken one. Covers the pure tally + summary helpers driving the new
 * "Backfill: session persisted N rows (M with motion) across K night(s)" line. Mirrors the Swift
 * BackfillerSessionTallyTests.
 */
class BackfillerSessionTallyTest {

    // rows = biometric streams only (HR, R-R, SpO2, skin-temp, resp, gravity); events/battery/steps are
    // housekeeping and must NOT inflate the count (matches the Swift tuple, which has no steps). motion = gravity.
    @Test fun chunkTallySumsBiometricRowsAndGravityOnly() {
        val counts = InsertCounts(hr = 10, rr = 4, events = 99, battery = 7, spo2 = 3, skinTemp = 2, steps = 50, resp = 1, gravity = 5)
        val (rows, motion, nights) = Backfiller.chunkTally(counts, emptyList())
        assertEquals(10 + 4 + 3 + 2 + 1 + 5, rows) // 25 — events(99)/battery(7)/steps(50) excluded
        assertEquals(5, motion)
        assertTrue(nights.isEmpty())
    }

    // nights collapse timestamps to distinct day-keys (ts / 86400): a chunk crossing a day boundary
    // counts two nights; same-day samples count once.
    @Test fun chunkTallyNightsAreDistinctDayKeys() {
        val day0 = 1_700_000_000L
        val sameDay = day0 + 3_600L
        val nextDay = day0 + 86_400L
        val (_, _, nights) = Backfiller.chunkTally(InsertCounts(), listOf(day0, sameDay, nextDay))
        assertEquals(setOf(day0 / 86_400L, nextDay / 86_400L), nights)
        assertEquals(2, nights.size)
    }

    // Silent when nothing persisted, so a console-only / caught-up session doesn't claim a false success.
    @Test fun sessionSummaryNullWhenNoRows() {
        assertNull(Backfiller.sessionSummaryLine(0, 0, 0, 0))
    }

    @Test fun sessionSummaryFormat() {
        assertEquals(
            "Backfill: session persisted 240 rows (180 with motion, 12 skin-temp) across 3 night(s).",
            Backfiller.sessionSummaryLine(240, 180, 12, 3),
        )
    }

    // #727: a strap banking HR/RR-only records (no DSP sleep block) persists rows but ZERO skin-temp,
    // so the line surfaces that 0 and "skin temp never appears" reports are self-diagnosing from the log.
    @Test fun sessionSummaryShowsZeroSkinTemp() {
        assertEquals(
            "Backfill: session persisted 872 rows (172 with motion, 0 skin-temp) across 1 night(s).",
            Backfiller.sessionSummaryLine(872, 172, 0, 1),
        )
    }

    // #783: trim=0xFFFFFFFF on a fresh run that banked NOTHING means "no banked history": the genuine
    // clock/charge guidance with the "fully charge it" hint.
    @Test fun noCursorLineNoRowsGivesNoHistoryGuidance() {
        val line = Backfiller.noCursorLine(0)
        assertTrue(line.contains("no banked history to offload"))
        assertTrue(line.contains("fully charge"))
    }

    // #783: trim=0xFFFFFFFF AFTER the auto-continuation has already persisted rows means "caught up",
    // NOT "no history". It must NOT emit the scary fully-charge guidance.
    @Test fun noCursorLineAfterRowsGivesCaughtUpLine() {
        val line = Backfiller.noCursorLine(240)
        assertTrue(line.contains("reached the end of available history"))
        assertTrue(line.contains("240 row(s)"))
        assertFalse(line.contains("no banked history"))
        assertFalse(line.contains("fully charge"))
    }

    // #42: trim=0xFFFFFFFF on the EMPTY tail of an auto-continue burst (this session banked 0 rows, but an
    // earlier session in the burst did \u2014 continuedAfterRows=true) means "caught up", NOT "no history". It
    // must NOT emit the scary fully-charge guidance even though rowsPersisted is 0.
    @Test fun noCursorLineContinuedAfterRowsGivesCaughtUpLine() {
        val line = Backfiller.noCursorLine(0, continuedAfterRows = true)
        assertTrue(line.contains("caught up"))
        assertFalse(line.contains("no banked history"))
        assertFalse(line.contains("fully charge"))
    }

    // #42: continuedAfterRows only softens the ZERO-row tail; a genuinely empty FRESH run (default false)
    // still gets the honest no-history guidance.
    @Test fun noCursorLineFreshEmptyStillGivesNoHistoryGuidance() {
        assertTrue(Backfiller.noCursorLine(0, continuedAfterRows = false).contains("no banked history"))
    }

    // No em-dash leaks into either branch (project hard rule).
    @Test fun noCursorLineHasNoEmDash() {
        assertFalse(Backfiller.noCursorLine(0).contains("\u2014"))
        assertFalse(Backfiller.noCursorLine(5).contains("\u2014"))
        assertFalse(Backfiller.noCursorLine(0, continuedAfterRows = true).contains("\u2014"))
    }

    // ---- #773 corrupt future-RTC detection ----

    // A genuine offload is PAST-dated; a past timestamp is never flagged.
    @Test fun futureRtcNotFlaggedForPastDate() {
        val now = 1_700_000_000L
        assertFalse(Backfiller.isCorruptFutureRtc(now - 86_400L, now))
        assertFalse(Backfiller.isCorruptFutureRtc(now, now))
    }

    // Ordinary forward skew under the 1-day tolerance is NOT a corrupt clock (no false alarm).
    @Test fun futureRtcToleratesSmallSkew() {
        val now = 1_700_000_000L
        assertFalse(Backfiller.isCorruptFutureRtc(now + 3_600L, now))
        // Exactly at the tolerance boundary is still OK (strictly greater trips it).
        assertFalse(Backfiller.isCorruptFutureRtc(now + Backfiller.FUTURE_RTC_TOLERANCE_SECONDS, now))
    }

    // A date days into the future can only be a corrupt strap RTC, so it's flagged.
    @Test fun futureRtcFlaggedForFarFutureDate() {
        val now = 1_700_000_000L
        assertTrue(Backfiller.isCorruptFutureRtc(now + 10L * 86_400L, now))
    }

    // The recovery hint names the cause + fix, reports days-ahead, and has no em-dash. Byte-identical to Swift.
    // #1683: the stale counterpart. A strap that stopped banking weeks ago and one that is caught up
    // produced the SAME "banked no sensor history" line, so neither the user nor a triager could tell
    // them apart — the reason #1541 stayed open and unactionable.

    @Test fun aCaughtUpOrBrieflyIdleStrapIsNotStale() {
        val now = 1_700_000_000L
        assertFalse(Backfiller.isStaleNewestRecord(null, now))          // no reading at all
        assertFalse(Backfiller.isStaleNewestRecord(0L, now))            // 0 is not a date
        assertFalse(Backfiller.isStaleNewestRecord(now, now))           // caught up
        assertFalse(Backfiller.isStaleNewestRecord(now - 86_400L, now)) // one night off-wrist is ordinary
    }

    @Test fun twoDaysIsTheBoundaryAndQualifies() {
        val now = 1_700_000_000L
        assertTrue(Backfiller.isStaleNewestRecord(now - 2L * 86_400L, now))
    }

    /** A future-dated record belongs to futureRtcLine; this rule must not also claim it. */
    @Test fun aFutureDatedRecordIsNotStale() {
        val now = 1_700_000_000L
        assertFalse(Backfiller.isStaleNewestRecord(now + 86_400L, now))
    }

    /**
     * The numbers from the #1683 capture: newest stored record 1785692420 against a wall clock of
     * 1787820941. The user was told only "banked no sensor history"; this says three weeks.
     */
    @Test fun staleRecordLineReportsTheRealCaptureAsTwentyFourDays() {
        val line = Backfiller.staleRecordLine(1_785_692_420L, 1_787_820_941L)
        assertTrue(line, line.contains("about 24 day(s) old"))
        assertTrue(line, line.contains("stopped saving history"))
        // The part the old advice omitted: charging alone has already been retried every connect.
        assertTrue(line, line.contains("re-sends the clock on every connect"))
        // The test that tells the user whether NOOP is even involved.
        assertTrue(line, line.contains("official WHOOP app"))
        assertFalse(line.contains("\u2014"))
    }

    /** States the fact, never the diagnosis: a drawered strap shows the same number innocently. */
    @Test fun staleRecordLineDoesNotAssertACorruptClock() {
        val line = Backfiller.staleRecordLine(1_700_000_000L - 20L * 86_400L, 1_700_000_000L)
        assertFalse(line, line.contains("corrupt"))
        assertTrue(line, line.contains("If you have worn it"))
    }

    /**
     * The banner is what the user READS; the log line needs a capture export. The standing banner omitted
     * the age entirely and PROMISED that charging "should" work - advice NOOP has effectively retried on
     * every connect for weeks, since it re-sends SET_CLOCK each time.
     */
    @Test fun staleRecordBannerDatesTheSilenceAndPromisesNothing() {
        val line = Backfiller.staleRecordBanner(1_785_692_420L, 1_787_820_941L)
        assertTrue(line, line.contains("about 24 day(s) old"))
        assertTrue(line, line.contains("If you have been wearing it"))
        assertTrue(line, line.contains("official WHOOP app"))
        assertFalse(line, line.contains("should start banking again"))
        assertFalse(line.contains("\u2014"))
    }

    @Test fun futureRtcLineWording() {
        val now = 1_700_000_000L
        val line = Backfiller.futureRtcLine(now + 10L * 86_400L, now)
        assertTrue(line.contains("10 day(s) in the FUTURE"))
        assertTrue(line.contains("clock (RTC) is corrupt"))
        assertTrue(line.contains("Fully charge"))
        assertFalse(line.contains("\u2014"))
    }

    // ---- #1 records-bearing 0xFFFFFFFF END must NOT false-alarm "no banked history" ----

    /**
     * #1: the no-cursor (0xFFFFFFFF) gate must pick its line on the row count that ALREADY includes THIS
     * END's own rows. A bad-clock/flash strap can emit records on the same no-cursor END; before the fix
     * the gate read sessionRowsPersisted at the TOP of finishChunk, before this chunk's rows were tallied,
     * so a records-bearing END logged the alarming "no banked history" line. The relocation moves the gate
     * AFTER `sessionRowsPersisted += rows`. This pins that ordering by replaying finishChunk's exact field
     * sequence through the SAME production helpers (chunkTally -> add rows -> noCursorLine): with this
     * END's rows added first, the no-cursor line is the neutral caught-up one, never the false alarm.
     */
    @Test fun recordsBearingNoCursorEndDoesNotFalseAlarm() {
        // This END carries records (a v25-style chunk decoding to gravity rows): chunkTally yields rows > 0.
        val counts = InsertCounts(gravity = 3)
        var sessionRowsPersisted = 0
        // finishChunk's persist-block ordering: tally THIS chunk, THEN add to the session total...
        val (rows, _, _) = Backfiller.chunkTally(counts, listOf(1_700_000_000L, 1_700_000_001L, 1_700_000_002L))
        sessionRowsPersisted += rows
        // ...and ONLY THEN does the relocated no-cursor gate read sessionRowsPersisted.
        val line = Backfiller.noCursorLine(sessionRowsPersisted)
        assertTrue("this END's own rows must be in the count", sessionRowsPersisted > 0)
        assertFalse("a records-bearing 0xFFFFFFFF END must NOT emit the false no-history alarm",
            line.contains("no banked history to offload"))
        assertFalse(line.contains("fully charge"))
        assertTrue("it should be the neutral caught-up line instead",
            line.contains("reached the end of available history"))
    }

    /**
     * #1 (the critical other half): a genuinely empty session (a 0xFFFFFFFF END with no accumulated
     * records, so zero rows persisted) STILL gets the real no-history guidance. The relocation must not
     * silence the legitimate case: with no persist block running, sessionRowsPersisted stays 0 and the
     * gate emits the genuine warning.
     */
    @Test fun trulyEmptyNoCursorEndStillWarnsNoHistory() {
        val sessionRowsPersisted = 0 // empty END: the persist block never runs, total stays 0
        val line = Backfiller.noCursorLine(sessionRowsPersisted)
        assertTrue("a truly-empty no-cursor session must still warn the strap has no banked history",
            line.contains("no banked history to offload"))
        assertTrue(line.contains("fully charge"))
    }
}
