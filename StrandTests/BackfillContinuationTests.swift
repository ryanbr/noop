import XCTest
@testable import Strand

/// Pins the #364 historical-sync auto-continue decision. The real bug: the strap offloads OLDEST-first
/// at ~60s/session with a 15-min floor and NO auto-continue, so on a deep backlog each connection drains
/// only one oldest pass then waits — "last night" can take many connections to reach even while the
/// strap stays connected. `BackfillContinuation.shouldAutoContinue` decides whether a session that ended
/// on the 60s IDLE cap (not a true HISTORY_COMPLETE) should immediately re-kick instead of tearing down
/// to the floor. Pure value type → no CoreBluetooth seam needed (mirrors MarginalRadioDetectorTests).
///
/// #928 pinned here too: the predicate takes the REAL wall clock (`wallNowUnix`) so a strap clock set in
/// the FUTURE (a "newest" more than 48 h ahead of the wall) is excluded from the backlog test instead of
/// reading as endless backlog. Fixtures pass an explicit wall-now consistent with their timestamps.
/// #1012 tightens it: a future-dated newest now stops guard 2b as well — its "real rows" are future-dated
/// too, so the drain ends after one pass instead of chasing the future range through the whole cap.
final class BackfillContinuationTests: XCTestCase {

    /// The fixtures' "now": all pre-#928 timestamps sit at or before this instant, so the plausibility
    /// check is inert for them and the original #364/#451/#25 semantics stay pinned unchanged.
    private let wallNow = 1_800_000_000

    /// The happy path: still connected, the strap is well ahead of our frontier, the trim advanced this
    /// session, and we're under the cap ⇒ continue immediately.
    func testContinuesWhenConnectedBehindAndAdvancing() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,            // strap newest
            ourFrontierTs: 1_800_000_000 - 86_400,   // our frontier a full day behind
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 200,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// #1144 phantom-gap spin: the strap reports a `newest` well AHEAD of our frontier (so guard 2a's gap
    /// holds) and the trim advanced — but the offload persisted ZERO rows. Continuing would re-fire 2a to
    /// the full cap in empty offloads, since the frontier can't advance without rows. An empty session must
    /// stop regardless of the reported gap.
    func testStopsWhenGapHoldsButSessionWasEmpty() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 400,      // 400s behind → 2a's 300s gap holds
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 0,             // …but nothing was actually offloaded
            lastTrimAdvanced: true,                  // trim u32 climbs on empty ENDs — not enough
            consecutiveCount: 0))
    }

    /// A dropped link must NOT auto-continue — the normal reconnect path owns it.
    func testStopsWhenDisconnected() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: false,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            wallNowUnix: wallNow,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// Caught up: the strap is NOT meaningfully ahead of our frontier ⇒ nothing left to fetch, don't spin.
    func testStopsWhenCaughtUp() {
        // Within the behind-gap (300s default): treat as caught up.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 120,      // only 2 min behind, under the 5-min gap
            wallNowUnix: wallNow,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// Exactly at the gap boundary is NOT "behind" (strictly-greater), so it stops — caught-up wins ties.
    func testGapBoundaryIsNotBehind() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 300,      // exactly the 300s gap
            wallNowUnix: wallNow,
            lastTrimAdvanced: true,
            consecutiveCount: 0,
            behindGapSeconds: 300))
        // One second past the gap IS behind.
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 301,
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 200,
            lastTrimAdvanced: true,
            consecutiveCount: 0,
            behindGapSeconds: 300))
    }

    /// The spin-detector: if the trim cursor did NOT advance this session (strap handing back
    /// console-only / refusing to trim), re-kicking would loop forever — so stop even though we're behind.
    func testStopsWhenTrimFrozen() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            wallNowUnix: wallNow,
            lastTrimAdvanced: false,                 // frozen cursor
            consecutiveCount: 0))
    }

    /// The hard per-connection cap: once we've already auto-continued maxAutoContinues times, stop and
    /// let the 15-min floor take over — a pathological strap can't pin the radio.
    func testStopsAtCap() {
        let cap = BackfillContinuation.defaultMaxAutoContinues
        // One below the cap still continues.
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 200,
            lastTrimAdvanced: true,
            consecutiveCount: cap - 1))
        // At the cap, stop.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            wallNowUnix: wallNow,
            lastTrimAdvanced: true,
            consecutiveCount: cap))
        // Above the cap, still stop.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            wallNowUnix: wallNow,
            lastTrimAdvanced: true,
            consecutiveCount: cap + 5))
    }

    /// Unknown range (no GET_DATA_RANGE yet, or no persisted frontier): we can't prove backlog remains,
    /// so don't auto-continue — let the periodic floor handle it conservatively.
    func testStopsWhenRangeUnknown() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: nil,                       // no GET_DATA_RANGE answer
            ourFrontierTs: 1_700_000_000,
            wallNowUnix: wallNow,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: nil,                       // nothing persisted yet
            wallNowUnix: wallNow,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// #451: GET_DATA_RANGE latched a STALE / wrong-epoch "newest" (e.g. a 2024 value when the real newest
    /// is 2026), which reads as BEHIND our frontier — the 2a "strap ahead" test fails and the old code
    /// concluded "caught up" and stopped after ONE session. But the trim advanced AND this session
    /// persisted real sensor rows, so the strap is demonstrably still handing over backlog ⇒ continue.
    func testContinuesWhenNewestStaleButRowsFlowing() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_700_000_000,            // stale 2023/24-epoch range answer…
            ourFrontierTs: 1_800_000_000,            // …reads as BEHIND our real 2026 frontier
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 240,           // but real rows came in this pass
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// The discriminator that keeps the #451 fallback safe: a genuinely caught-up / console-only strap
    /// persists ZERO rows, so even with the trim nudging it must NOT spin — the 0-row fallback returns false.
    func testStopsWhenNewestStaleAndNoRows() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_700_000_000,            // stale/behind range answer
            ourFrontierTs: 1_800_000_000,
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 0,             // nothing actually persisted ⇒ caught up / stuck
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// GET_DATA_RANGE not answered at all (nil) but real rows are flowing and the trim advanced ⇒ keep
    /// draining. Without the rows fallback this would have stalled on the unknown-range guard.
    func testContinuesWhenRangeUnknownButRowsFlowing() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: nil,                       // no GET_DATA_RANGE answer
            ourFrontierTs: 1_800_000_000,
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 180,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// The rows-flowing fallback never overrides the earlier guards: a frozen trim, the cap, and a dropped
    /// link still stop even with rows > 0 (guards 1/3/4 are checked before 2b).
    func testRowsFallbackStillRespectsHardGuards() {
        // Frozen trim wins over rows.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_700_000_000,
            ourFrontierTs: 1_800_000_000,
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 240,
            lastTrimAdvanced: false,                  // frozen cursor
            consecutiveCount: 0))
        // The cap wins over rows.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_700_000_000,
            ourFrontierTs: 1_800_000_000,
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 240,
            lastTrimAdvanced: true,
            consecutiveCount: BackfillContinuation.defaultMaxAutoContinues))
        // A dropped link wins over rows.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: false,
            strapNewestTs: 1_700_000_000,
            ourFrontierTs: 1_800_000_000,
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 240,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// A multi-pass drain: a deep backlog continues pass after pass (each advancing the frontier toward
    /// the strap's newest) until either we catch up OR the cap is hit — never silently stalling at one.
    func testMultiPassDrainUntilCaughtUpOrCapped() {
        let strapNewest = 1_800_000_000
        // Backlog DEEPER than the cap (each pass advances the frontier one day) so the drain is bounded by
        // the cap, not by catching up — that is the invariant this test pins, independent of the cap value.
        var frontier = strapNewest - (BackfillContinuation.defaultMaxAutoContinues + 5) * 86_400
        var count = 0
        var passes = 0
        while BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: strapNewest,
            ourFrontierTs: frontier,
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 200,
            lastTrimAdvanced: true,
            consecutiveCount: count) {
            // Each pass drains ~a day of the oldest backlog and counts as one auto-continue.
            frontier += 86_400
            count += 1
            passes += 1
            XCTAssertLessThanOrEqual(passes, BackfillContinuation.defaultMaxAutoContinues + 1,
                                     "auto-continue must be bounded — it can't loop forever")
        }
        // It stopped because it hit the cap (deep backlog), not because it silently stalled at pass 1.
        XCTAssertEqual(count, BackfillContinuation.defaultMaxAutoContinues)
    }

    /// #533: a genuine deep backlog must keep draining PAST the old 6-pass cap in one connection, instead
    /// of being throttled to the 15-min floor mid-drain. At 10 consecutive continues with the strap still
    /// a day ahead of our frontier and the trim advancing, it must still continue (the cap is now higher).
    func testContinuesPastOldSixCapOnDeepBacklog() {
        XCTAssertGreaterThan(BackfillContinuation.defaultMaxAutoContinues, 6)   // pins the #533 raise
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,   // a full day behind
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 200,
            lastTrimAdvanced: true,
            consecutiveCount: 10))                    // well past the old cap of 6
    }

    // MARK: #25 — HISTORY_COMPLETE-sliced offloads

    /// #25: the user goes to bed with a charged strap, the phone dies, and overnight banks a deep backlog.
    /// Some strap firmware segments that offload into many SMALL HISTORY_COMPLETE slices rather than one
    /// long session. Before #25, exitBackfilling only auto-continued on a 60s TIMEOUT, so a strap that
    /// completed-then-stopped between slices stalled until the 15-min floor — "last night" drained an hour
    /// at a time. The predicate is reason-agnostic: a small completion that is STILL far behind the strap's
    /// newest, with the trim advancing and real rows banked, must auto-continue exactly as a timeout would.
    func testSmallHistoryCompleteStillBehindContinues() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 6 * 3600,   // still 6 h behind after this slice
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 90,              // a small slice, but real rows landed
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// #25: the LAST slice of the overnight drain brings us level with the strap's newest record. Firing
    /// the auto-continue on HISTORY_COMPLETE must NOT spin a caught-up strap — the frontier is now within
    /// the behind-gap, so the predicate returns false and the session tears down to the periodic floor.
    func testFinalHistoryCompleteCaughtUpStops() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 60,         // within the 5-min gap ⇒ caught up
            wallNowUnix: wallNow,
            // A genuinely caught-up strap hands over NO new rows on the final END (empty / console-only),
            // so the #451 guard-2b "keep draining if still persisting real backlog" does not fire and the
            // predicate returns false. (12 rows + advanced trim would correctly KEEP going per #451.)
            rowsPersistedThisSession: 0,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// #25: a pathological strap that emits an endless run of tiny far-behind HISTORY_COMPLETE slices must
    /// still be bounded by the per-connection cap — otherwise firing on completion would let it pin the
    /// radio. Each slice persists rows and stays behind, yet the drain stops at exactly maxAutoContinues.
    func testHistoryCompleteSlicesAreCappedNotRunaway() {
        var count = 0
        var continued = 0
        while BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 7 * 86_400, // never catches up — frontier stays far behind
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 30,              // every tiny slice banks a few rows
            lastTrimAdvanced: true,
            consecutiveCount: count) {
            count += 1
            continued += 1
            XCTAssertLessThanOrEqual(continued, BackfillContinuation.defaultMaxAutoContinues + 1,
                                     "HISTORY_COMPLETE slices must be capped, not spin forever")
        }
        XCTAssertEqual(count, BackfillContinuation.defaultMaxAutoContinues)
    }

    // MARK: #928: strap clock set in the FUTURE

    /// #928 THE BUG: a strap clock set ahead makes the range "newest" future-dated, which reads as
    /// permanently AHEAD of every real frontier, so guard 2a fired on every connect and burned up to the
    /// full cap in EMPTY offloads. An implausibly future newest (more than 48 h past the wall clock) must
    /// be EXCLUDED from the backlog test: with no real rows this session there is no evidence of backlog,
    /// so the very first empty session stops the drain.
    func testFutureClockNewestExcludedStopsEmptySpin() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: wallNow + 30 * 86_400,     // strap clock a month ahead of the wall
            ourFrontierTs: wallNow - 600,             // we're genuinely caught up to 10 min ago
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 0,              // the offloads come back empty
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// #1012 (FLIPS the original #928-era assertion, which had this continuing): a FUTURE-dated range
    /// answer means the strap BANKED future-dated records (#928), so the rows this session persisted are
    /// themselves future-timestamped — NOT evidence of genuine backlog. Under the old "real rows keep
    /// draining" logic, 2b chased the future-dated range through the whole 6-kick cap, each pass run to
    /// its idle timeout: a ~1-min sync took ~15. Stop after the single pass; the periodic floor keeps
    /// draining across connects. (The stale/PAST-epoch case 2b exists for is pinned separately by
    /// testContinuesWhenNewestStaleButRowsFlowing and stays continuing.)
    func testFutureClockNewestStopsEvenOnRealRows() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: wallNow + 30 * 86_400,     // future-dated answer (strap clock a month ahead)
            ourFrontierTs: wallNow - 600,
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 240,            // rows banked — but they're future-dated too
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// #1012 the reported burn, end to end: a future-clock strap kept handing over rows pass after pass
    /// (18497, 850, 13212, 1729, 92676 in the reporter's log), so the old 2b chained through the whole
    /// cap. The gated predicate must refuse the SECOND pass no matter how many rows keep flowing — the
    /// chain length is exactly one (the pass that already ran before the decision).
    func testFutureClockChainStopsAfterOnePass() {
        for rows in [18_497, 850, 13_212, 1_729, 92_676] {
            XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
                stillConnected: true,
                strapNewestTs: wallNow + 158 * 86_400,   // ~158 days ahead, the reporter's strap
                ourFrontierTs: wallNow - 600,
                wallNowUnix: wallNow,
                rowsPersistedThisSession: rows,
                lastTrimAdvanced: true,
                consecutiveCount: 0),
                "a future-dated range must never re-kick, even with \(rows) rows persisted")
        }
    }

    /// #1012 helper: the future-dated discriminator shared by the predicate and the call-site stop log.
    /// nil = unknown range (NOT future-dated — the #451 stale-epoch rescue still applies); exactly 48 h
    /// ahead is plausible skew (strictly-greater trips it); one second past is future-dated.
    func testIsFutureDatedNewestBoundary() {
        XCTAssertFalse(BackfillContinuation.isFutureDatedNewest(nil, wallNowUnix: wallNow))
        XCTAssertFalse(BackfillContinuation.isFutureDatedNewest(wallNow + 48 * 3600, wallNowUnix: wallNow))
        XCTAssertTrue(BackfillContinuation.isFutureDatedNewest(wallNow + 48 * 3600 + 1, wallNowUnix: wallNow))
    }

    /// #928 boundary: exactly 48 h ahead is still plausible (the guard is strictly-greater, absorbing
    /// timezone confusion and mild drift); one second past it is implausible and excluded.
    func testFutureSkewBoundary() {
        // Exactly at the skew cap: still trusted, and far ahead of the frontier ⇒ continue.
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: wallNow + 48 * 3600,
            ourFrontierTs: wallNow - 86_400,
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 200,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
        // One second past the cap: excluded, and an empty session must not continue.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: wallNow + 48 * 3600 + 1,
            ourFrontierTs: wallNow - 86_400,
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 0,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// #928: mild clock skew (an hour ahead, i.e. a timezone hiccup or drift) stays inside the 48 h
    /// tolerance, so a genuinely-behind frontier still auto-continues exactly as before the clamp.
    func testMildFutureSkewStillTrusted() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true,
            strapNewestTs: wallNow + 3600,            // an hour ahead: plausible skew, not a broken clock
            ourFrontierTs: wallNow - 86_400,          // a real day of backlog
            wallNowUnix: wallNow,
            rowsPersistedThisSession: 200,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }
}
