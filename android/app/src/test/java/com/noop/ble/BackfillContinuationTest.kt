package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #364 historical-sync auto-continue decision ([WhoopBleClient.shouldAutoContinue]). The real
 * bug: the strap offloads OLDEST-first at ~60s/session with a 15-min floor and NO auto-continue, so on a
 * deep backlog each connection drains only the oldest pass then waits — "last night" can take many
 * connections to reach even while the strap stays connected. The predicate decides whether a session that
 * ended on the 60s IDLE cap (not a true HISTORY_COMPLETE) should immediately re-kick instead of tearing
 * down to the floor. Pure → no live GATT stack needed; mirrors the Swift BackfillContinuationTests
 * byte-for-behaviour.
 *
 * #928 pinned here too: the predicate takes the REAL wall clock (`wallNowUnix`) so a strap clock set in
 * the FUTURE (a "newest" more than 48 h ahead of the wall) is excluded from the backlog test instead of
 * reading as endless backlog. Fixtures pass an explicit wall-now consistent with their timestamps.
 * #1012 tightens it: a future-dated newest now stops guard 2b as well — its "real rows" are future-dated
 * too, so the drain ends after one pass instead of chasing the future range through the whole cap.
 */
class BackfillContinuationTest {

    /** The fixtures' "now": all pre-#928 timestamps sit at or before this instant, so the plausibility
     *  check is inert for them and the original #364/#451/#25 semantics stay pinned unchanged. */
    private val wallNow = 1_800_000_000L

    /** Happy path: connected, strap well ahead of our frontier, trim advanced, under the cap ⇒ continue. */
    @Test
    fun continues_whenConnectedBehindAndAdvancing() {
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 86_400L,   // a full day behind
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 200,
            ),
        )
    }

    /** #1144 phantom-gap spin: the strap reports a `newest` well AHEAD of our frontier (so guard 2a's gap
     *  holds) and the trim advanced — but the offload persisted ZERO rows. Continuing would re-fire 2a to
     *  the full cap in empty offloads, because the frontier can't advance without rows. An empty session
     *  must stop regardless of the reported gap. */
    @Test
    fun stops_whenGapHoldsButSessionWasEmpty() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 400L,   // 400s behind → 2a's 300s gap holds
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,                 // trim u32 climbs on empty ENDs — not enough
                consecutiveCount = 0,
                rowsPersistedThisSession = 0,            // …but nothing was actually offloaded
            ),
        )
    }

    /** A dropped link must NOT auto-continue — the normal reconnect path owns it. */
    @Test
    fun stops_whenDisconnected() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = false,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
            ),
        )
    }

    /** Caught up: the strap is not meaningfully ahead of our frontier ⇒ nothing left to fetch. */
    @Test
    fun stops_whenCaughtUp() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 120L,      // 2 min behind, under the 5-min gap
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
            ),
        )
    }

    /** The gap boundary is NOT "behind" (strictly-greater); one second past it IS. */
    @Test
    fun gapBoundary_isNotBehind() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 300L,      // exactly the 300s gap
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                behindGapSeconds = 300L,
            ),
        )
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 301L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                behindGapSeconds = 300L,
                rowsPersistedThisSession = 200,
            ),
        )
    }

    /** Spin-detector: a frozen trim cursor (console-only / refusing to trim) must NOT re-kick. */
    @Test
    fun stops_whenTrimFrozen() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = false,
                consecutiveCount = 0,
            ),
        )
    }

    /** Hard per-connection cap: at/above the cap we stop and let the 900s timer take over. */
    @Test
    fun stops_atCap() {
        val cap = WhoopBleClient.MAX_AUTO_CONTINUES
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = cap - 1,
                rowsPersistedThisSession = 200,
            ),
        )
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = cap,
            ),
        )
    }

    /** #533: a genuine deep backlog must keep draining PAST the old 6-pass cap in one connection, instead
     *  of being throttled to the 15-min floor mid-drain. At 10 consecutive continues with the strap still
     *  a day ahead of our frontier and the trim advancing, it must still continue (the cap is now higher). */
    @Test
    fun continues_pastOldSixCap_onDeepBacklog() {
        assertTrue(WhoopBleClient.MAX_AUTO_CONTINUES > 6)   // pins the #533 raise
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 86_400L,   // a full day behind
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 10,                       // well past the old cap of 6
                rowsPersistedThisSession = 200,
            ),
        )
    }

    /** Unknown range (no GET_DATA_RANGE answer, or nothing persisted yet) ⇒ don't auto-continue. */
    @Test
    fun stops_whenRangeUnknown() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = null,
                ourFrontierTs = 1_700_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
            ),
        )
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = null,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
            ),
        )
    }

    /** #451: GET_DATA_RANGE latched a STALE / wrong-epoch "newest" (e.g. 2024 when the real newest is
     *  2026), which reads as BEHIND our frontier — the old "strap ahead" test fails and we'd stop after one
     *  session. But the trim advanced AND this pass persisted real sensor rows ⇒ keep draining. */
    @Test
    fun continues_whenNewestStaleButRowsFlowing() {
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_700_000_000L,             // stale range answer…
                ourFrontierTs = 1_800_000_000L,             // …reads as behind our real frontier
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 240,
            ),
        )
    }

    /** The discriminator that keeps the #451 fallback safe: a caught-up / console-only strap persists ZERO
     *  rows, so even with the trim nudging it must NOT spin. */
    @Test
    fun stops_whenNewestStaleAndNoRows() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_700_000_000L,
                ourFrontierTs = 1_800_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 0,
            ),
        )
    }

    /** GET_DATA_RANGE unanswered (null) but real rows flowing and the trim advanced ⇒ keep draining. */
    @Test
    fun continues_whenRangeUnknownButRowsFlowing() {
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = null,
                ourFrontierTs = 1_800_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 180,
            ),
        )
    }

    /** The rows-flowing fallback never overrides the earlier guards: frozen trim, cap, and dropped link
     *  still stop even with rows > 0. */
    @Test
    fun rowsFallback_stillRespectsHardGuards() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_700_000_000L,
                ourFrontierTs = 1_800_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = false,                   // frozen cursor wins
                consecutiveCount = 0,
                rowsPersistedThisSession = 240,
            ),
        )
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_700_000_000L,
                ourFrontierTs = 1_800_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = WhoopBleClient.MAX_AUTO_CONTINUES,   // cap wins
                rowsPersistedThisSession = 240,
            ),
        )
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = false,                     // dropped link wins
                strapNewestTs = 1_700_000_000L,
                ourFrontierTs = 1_800_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 240,
            ),
        )
    }

    /** A deep backlog drains pass-after-pass until caught up OR the cap is hit — never stalling at one. */
    @Test
    fun multiPassDrain_untilCaughtUpOrCapped() {
        val strapNewest = 1_800_000_000L
        // Backlog DEEPER than the cap (each pass advances the frontier one day) so the drain is bounded by
        // the cap, not by catching up — that is the invariant this test pins, independent of the cap value.
        var frontier = strapNewest - (WhoopBleClient.MAX_AUTO_CONTINUES + 5).toLong() * 86_400L
        var count = 0
        var passes = 0
        while (WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = strapNewest,
                ourFrontierTs = frontier,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = count,
                rowsPersistedThisSession = 200,   // each pass lands real rows (that's why the frontier advances)
            )
        ) {
            frontier += 86_400L
            count += 1
            passes += 1
            assertTrue("auto-continue must be bounded", passes <= WhoopBleClient.MAX_AUTO_CONTINUES + 1)
        }
        assertEquals(WhoopBleClient.MAX_AUTO_CONTINUES, count)
    }

    // #25 — HISTORY_COMPLETE-sliced offloads

    /** #25: the user goes to bed with a charged strap, the phone dies, and overnight banks a deep backlog.
     *  Some strap firmware segments that offload into many SMALL HISTORY_COMPLETE slices rather than one
     *  long session. Before #25, exitBackfilling only auto-continued on a 60s TIMEOUT, so a strap that
     *  completed-then-stopped between slices stalled until the periodic floor — "last night" drained an hour
     *  at a time. The predicate is reason-agnostic: a small completion STILL far behind the strap's newest,
     *  with the trim advancing and real rows banked, must auto-continue exactly as a timeout would. */
    @Test
    fun smallHistoryComplete_stillBehind_continues() {
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 6L * 3600L,   // still 6 h behind after this slice
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 90,                 // a small slice, but real rows landed
            ),
        )
    }

    /** #25: the LAST slice of the overnight drain brings us level with the strap's newest record. Firing
     *  the auto-continue on HISTORY_COMPLETE must NOT spin a caught-up strap — the frontier is now within
     *  the behind-gap, so the predicate returns false and the session tears down to the periodic floor. */
    @Test
    fun finalHistoryComplete_caughtUp_stops() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 60L,          // within the 5-min gap ⇒ caught up
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                // A genuinely caught-up strap hands over NO new rows on the final END (empty / console-only).
                // 0 rows means the #451 guard-2b "keep draining if still persisting real backlog" does NOT
                // fire, so the predicate returns false and the session tears down to the periodic floor.
                rowsPersistedThisSession = 0,
            ),
        )
    }

    /** #25: a pathological strap that emits an endless run of tiny far-behind HISTORY_COMPLETE slices must
     *  still be bounded by the per-connection cap — otherwise firing on completion would let it pin the
     *  radio. Each slice persists rows and stays behind, yet the drain stops at exactly MAX_AUTO_CONTINUES. */
    @Test
    fun historyCompleteSlices_areCapped_notRunaway() {
        var count = 0
        var continued = 0
        while (WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 7L * 86_400L, // never catches up — frontier stays far behind
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = count,
                rowsPersistedThisSession = 30,                 // every tiny slice banks a few rows
            )
        ) {
            count += 1
            continued += 1
            assertTrue("HISTORY_COMPLETE slices must be capped, not spin forever", continued <= WhoopBleClient.MAX_AUTO_CONTINUES + 1)
        }
        assertEquals(WhoopBleClient.MAX_AUTO_CONTINUES, count)
    }

    // #928: strap clock set in the FUTURE

    /** #928 THE BUG: a strap clock set ahead makes the range "newest" future-dated, which reads as
     *  permanently AHEAD of every real frontier, so the backlog guard fired on every connect and burned up
     *  to the full cap in EMPTY offloads. An implausibly future newest (more than 48 h past the wall
     *  clock) must be EXCLUDED from the backlog test: with no real rows this session there is no evidence
     *  of backlog, so the very first empty session stops the drain. */
    @Test
    fun futureClockNewest_excluded_stopsEmptySpin() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = wallNow + 30L * 86_400L,   // strap clock a month ahead of the wall
                ourFrontierTs = wallNow - 600L,            // we're genuinely caught up to 10 min ago
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 0,              // the offloads come back empty
            ),
        )
    }

    /** #1012 (FLIPS the original #928-era assertion, which had this continuing): a FUTURE-dated range
     *  answer means the strap BANKED future-dated records (#928), so the rows this session persisted are
     *  themselves future-timestamped — NOT evidence of genuine backlog. Under the old "real rows keep
     *  draining" logic, 2b chased the future-dated range through the whole 6-kick cap, each pass run to
     *  its idle timeout: a ~1-min sync took ~15. Stop after the single pass; the periodic floor keeps
     *  draining across connects. (The stale/PAST-epoch case 2b exists for is pinned separately by
     *  continues_whenNewestStaleButRowsFlowing and stays continuing.) */
    @Test
    fun futureClockNewest_stopsEvenOnRealRows() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = wallNow + 30L * 86_400L,   // future-dated answer (strap clock a month ahead)
                ourFrontierTs = wallNow - 600L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 240,            // rows banked — but they're future-dated too
            ),
        )
    }

    /** #1012 the reported burn, end to end: a future-clock strap kept handing over rows pass after pass
     *  (18497, 850, 13212, 1729, 92676 in the reporter's log), so the old 2b chained through the whole
     *  cap. The gated predicate must refuse the SECOND pass no matter how many rows keep flowing — the
     *  chain length is exactly one (the pass that already ran before the decision). */
    @Test
    fun futureClockChain_stopsAfterOnePass() {
        for (rows in listOf(18_497, 850, 13_212, 1_729, 92_676)) {
            assertFalse(
                "a future-dated range must never re-kick, even with $rows rows persisted",
                WhoopBleClient.shouldAutoContinue(
                    stillConnected = true,
                    strapNewestTs = wallNow + 158L * 86_400L,   // ~158 days ahead, the reporter's strap
                    ourFrontierTs = wallNow - 600L,
                    wallNowUnix = wallNow,
                    lastTrimAdvanced = true,
                    consecutiveCount = 0,
                    rowsPersistedThisSession = rows,
                ),
            )
        }
    }

    /** #1012 helper: the future-dated discriminator shared by the predicate and the call-site stop log.
     *  null = unknown range (NOT future-dated — the #451 stale-epoch rescue still applies); exactly 48 h
     *  ahead is plausible skew (strictly-greater trips it); one second past is future-dated. */
    @Test
    fun isFutureDatedNewest_boundary() {
        assertFalse(WhoopBleClient.isFutureDatedNewest(null, wallNow))
        assertFalse(WhoopBleClient.isFutureDatedNewest(wallNow + 48L * 3600L, wallNow))
        assertTrue(WhoopBleClient.isFutureDatedNewest(wallNow + 48L * 3600L + 1L, wallNow))
    }

    /** #928 boundary: exactly 48 h ahead is still plausible (the guard is strictly-greater, absorbing
     *  timezone confusion and mild drift); one second past it is implausible and excluded. */
    @Test
    fun futureSkewBoundary() {
        // Exactly at the skew cap: still trusted, and far ahead of the frontier ⇒ continue.
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = wallNow + 48L * 3600L,
                ourFrontierTs = wallNow - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 200,
            ),
        )
        // One second past the cap: excluded, and an empty session must not continue.
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = wallNow + 48L * 3600L + 1L,
                ourFrontierTs = wallNow - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 0,
            ),
        )
    }

    /** #928: mild clock skew (an hour ahead, i.e. a timezone hiccup or drift) stays inside the 48 h
     *  tolerance, so a genuinely-behind frontier still auto-continues exactly as before the clamp. */
    @Test
    fun mildFutureSkew_stillTrusted() {
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = wallNow + 3600L,           // an hour ahead: plausible skew, not a broken clock
                ourFrontierTs = wallNow - 86_400L,         // a real day of backlog
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 200,
            ),
        )
    }
}
