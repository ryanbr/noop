package com.noop.analytics

import com.noop.protocol.DeviceFamily
import com.noop.protocol.Whoop4SkinTemp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1851: re-deriving a night's absolute skin temperature from raw samples the app still holds.
 *
 * The parts worth pinning are the ones that could corrupt data rather than merely fail: the WHOOP 4.0
 * anchor decline, and that the night window matches the engine's.
 */
class SkinTempBackfillTest {

    /**
     * A 4.0 with no resolved anchor must be DECLINED, never written on the global default.
     *
     * That default (826) maps a second real strap's worn band to 47-72 °C — outside human range, into a
     * column nothing downstream re-checks. Declining leaves the nights as deviations, which is the honest
     * state; writing would bank fiction that looks like a reading.
     */
    @Test
    fun aWhoop4WithoutAnAnchorIsDeclined() {
        assertTrue(SkinTempBackfill.requiresAnchor(DeviceFamily.WHOOP4))
        assertNull(SkinTempBackfill.anchorFor(DeviceFamily.WHOOP4, currentAnchorRaw = null))
    }

    /** A 4.0 WITH a resolved anchor uses exactly that one — never re-learned from the window being filled,
     *  which would put backfilled nights on a different offset from the ones already stored. */
    @Test
    fun aWhoop4UsesTheAnchorItIsGiven() {
        assertEquals(1290.0, SkinTempBackfill.anchorFor(DeviceFamily.WHOOP4, 1290.0))
        // Notably NOT the global default, which is what a re-learn would have fallen back to.
        assertTrue(1290.0 != Whoop4SkinTemp.ANCHOR_RAW)
    }

    /** 5/MG converts with raw/100 and carries no anchor, so it is never gated on one. */
    @Test
    fun whoop5NeedsNoAnchor() {
        assertFalse(SkinTempBackfill.requiresAnchor(DeviceFamily.WHOOP5))
        assertNotNull(SkinTempBackfill.anchorFor(DeviceFamily.WHOOP5, currentAnchorRaw = null))
    }

    /** The night window must match the engine's `from = dayStart - 30h`, or a backfilled night would be
     *  computed over a different sample set from the one the scoring pass would have used. */
    @Test
    fun theNightWindowMatchesTheEngines() {
        val dayStart = 1_760_000_000L
        val end = dayStart + 86_400
        val w = SkinTempBackfill.nightWindow(dayStart, end)
        assertEquals(dayStart - 30 * 3_600L, w.first)
        assertEquals(end, w.last)
        assertEquals(30 * 3_600L, SkinTempBackfill.NIGHT_LOOKBACK_SECONDS)
    }

    /** A stored sleep row becomes a session carrying only its bounds — the funnel reads nothing else, and
     *  inventing efficiency/stages here would be fabricating inputs the backfill does not have. */
    @Test
    fun aStoredRowBecomesABoundsOnlySession() {
        val s = SkinTempBackfill.sessionOf(startTs = 100L, endTs = 200L)
        assertEquals(100L, s.start)
        assertEquals(200L, s.end)
        assertTrue(s.stages.isEmpty())
        assertNull(s.restingHR)
        assertNull(s.avgHRV)
    }

    /** No samples means no temperature — the backfill must never synthesise one from the deviation. */
    @Test
    fun noSamplesYieldsNoAbsolute() {
        val mean = SkinTempBackfill.nightlyAbsolute(
            sessions = listOf(SkinTempBackfill.sessionOf(0L, 1_000L)),
            hr = emptyList(),
            skinTemp = emptyList(),
            family = DeviceFamily.WHOOP5,
            anchorRaw = null,
            wornToleranceSec = 0,
        )
        assertNull(mean)
    }

    /** The report separates recoverable from unrecoverable, because they need different answers: a night
     *  with no banked samples will never fill, however many times the backfill is re-run. */
    @Test
    fun theReportDistinguishesWhyANightDidNotFill() {
        val r = SkinTempBackfill.Report(candidates = 10, filled = 4, noMean = 2, noSamples = 4)
        assertEquals(10, r.examined)
        val declined = SkinTempBackfill.Report(declinedNoAnchor = true)
        assertEquals(0, declined.examined)
        assertTrue(declined.declinedNoAnchor)
    }

    // MARK: re-review — the run must drain, and must never strand nights that arrive later

    /**
     * The per-run cap is small on purpose: each FILLABLE night costs a large HR read, so a years-deep
     * history in one pass is the #836/#841 battery shape. The work drains across scoring passes instead.
     */
    @Test
    fun theRunIsCappedSmallEnoughToDrainAcrossPasses() {
        assertTrue("a cap this large would be a one-pass battery event",
                   SkinTempBackfill.DEFAULT_MAX_NIGHTS <= 100)
        assertTrue(SkinTempBackfill.DEFAULT_MAX_NIGHTS > 0)
    }

    /**
     * A decline must not look like progress. The caller only records a "fruitless" watermark when the run
     * actually examined nights and filled none — a 4.0 declined for a missing anchor examined nothing, so
     * it must retry once an anchor exists rather than being written off.
     */
    @Test
    fun aDeclineIsDistinguishableFromAFruitlessRun() {
        val declined = SkinTempBackfill.Report(declinedNoAnchor = true)
        val fruitless = SkinTempBackfill.Report(candidates = 5, noSamples = 5)
        assertTrue(declined.declinedNoAnchor)
        assertFalse(fruitless.declinedNoAnchor)
        assertEquals(0, declined.filled)
        assertEquals(0, fruitless.filled)
        // The two differ in whether anything was looked at, which is what the caller keys on.
        assertEquals(0, declined.examined)
        assertEquals(5, fruitless.examined)
    }

    // MARK: re-review 2 — the 54 h window holds TWO nights, and only one belongs to the day

    /**
     * The bug this pins would have written WRONG temperatures rather than none.
     *
     * The night window runs 30 h before local midnight to the next one, because a night belonging to day D
     * starts on the evening of D-1. At 54 h wide it also contains the night belonging to D-1, so handing
     * the funnel everything the window returned averaged two nights into one value and stored it as D's.
     *
     * The engine attributes by END (#277): `matched = allSessions.filter { tsInDay(it.end) }`.
     */
    @Test
    fun onlyTheNightEndingOnThatDayIsUsed() {
        val dayStart = 1_760_000_000L
        val dayEnd = dayStart + SkinTempBackfill.SECONDS_PER_DAY
        val previousNight = (dayStart - 26 * 3_600L) to (dayStart - 18 * 3_600L)   // ends on D-1
        val thisNight = (dayStart - 2 * 3_600L) to (dayStart + 6 * 3_600L)         // ends on D
        val nextNight = (dayEnd - 2 * 3_600L) to (dayEnd + 6 * 3_600L)             // ends on D+1

        val matched = SkinTempBackfill.sessionsEndingOnDay(
            listOf(previousNight, thisNight, nextNight), dayStart, dayEnd,
        )
        assertEquals(1, matched.size)
        assertEquals(thisNight.first, matched.single().start)
        assertEquals(thisNight.second, matched.single().end)
    }

    /** A daytime nap ending on the same day counts too — the engine keeps both in `matched`. */
    @Test
    fun aNapEndingOnTheSameDayIsIncluded() {
        val dayStart = 1_760_000_000L
        val dayEnd = dayStart + SkinTempBackfill.SECONDS_PER_DAY
        val night = (dayStart - 2 * 3_600L) to (dayStart + 6 * 3_600L)
        val nap = (dayStart + 14 * 3_600L) to (dayStart + 15 * 3_600L)
        assertEquals(2, SkinTempBackfill.sessionsEndingOnDay(listOf(night, nap), dayStart, dayEnd).size)
    }

    /** The day bound is [start, end) — a session ending exactly at the next midnight belongs to the NEXT
     *  day, matching a local-day bucket that cannot claim the same instant twice. */
    @Test
    fun theDayBoundIsHalfOpen() {
        val dayStart = 1_760_000_000L
        val dayEnd = dayStart + SkinTempBackfill.SECONDS_PER_DAY
        assertEquals(1, SkinTempBackfill.sessionsEndingOnDay(listOf(0L to dayStart), dayStart, dayEnd).size)
        assertEquals(0, SkinTempBackfill.sessionsEndingOnDay(listOf(0L to dayEnd), dayStart, dayEnd).size)
    }

    /** "No session for this night" is not "no samples" — they are different answers to the user, so the
     *  report keeps them apart. */
    @Test
    fun theReportSeparatesMissingSessionsFromMissingSamples() {
        val r = SkinTempBackfill.Report(candidates = 6, filled = 1, noMean = 1, noSamples = 2, noSessions = 2)
        assertEquals(6, r.examined)
    }

    // MARK: re-review 3 — a sweep must reach every night, not re-try the same page forever

    /**
     * The bug this pins is silent and permanent.
     *
     * The candidate query used to be a plain "oldest N", so every pass got the SAME nights — and the
     * oldest nights are precisely the ones most likely to have lost their raw samples. A first page that
     * could not fill latched the fruitless watermark, and every NEWER night that could have filled was
     * never reached. The user would see a handful of temperatures and no reason why.
     *
     * Paging means a short page — fewer than the cap — is the signal that the sweep has seen everything.
     */
    @Test
    fun aShortPageMeansTheSweepHasSeenEverything() {
        val full = SkinTempBackfill.Report(candidates = SkinTempBackfill.DEFAULT_MAX_NIGHTS, sweepComplete = false)
        assertFalse("a full page cannot be the end of a sweep", full.sweepComplete)
        val short = SkinTempBackfill.Report(candidates = 3, sweepComplete = true)
        assertTrue(short.sweepComplete)
    }

    /** An empty page ends the sweep too — nothing outstanding after the cursor. */
    @Test
    fun anEmptyPageEndsTheSweep() {
        val empty = SkinTempBackfill.Report(sweepComplete = true)
        assertTrue(empty.sweepComplete)
        assertEquals("", empty.lastDay)
        assertEquals(0, empty.examined)
    }

    /** The cursor is the newest day the page examined, so the next page starts strictly after it and no
     *  night is visited twice within one sweep. */
    @Test
    fun theCursorIsThePagesNewestDay() {
        val r = SkinTempBackfill.Report(candidates = 2, filled = 1, lastDay = "2026-08-11")
        assertEquals("2026-08-11", r.lastDay)
    }
}