import XCTest
@testable import OuraProtocol

/// Pins the Oura history drain + resume-cursor decisions (#91 / #291) that used to live untested inside
/// OuraLiveSource and silently regressed in a BLE refactor. Pure decisions — no ring, no BLE.
final class OuraHistoryDrainTests: XCTestCase {

    // MARK: drain continuation

    func testDrainCompletesWhenBytesLeftZero() {
        var d = OuraHistoryDrain()
        // moreData == false is the healthy end, regardless of the counters.
        XCTAssertFalse(d.onSummary(bytesLeft: 0, moreData: false, elapsedSeconds: 0))
    }

    func testDrainContinuesWhileBytesLeftShrinks() {
        var d = OuraHistoryDrain()
        XCTAssertTrue(d.onSummary(bytesLeft: 400_873, moreData: true, elapsedSeconds: 1))
        XCTAssertTrue(d.onSummary(bytesLeft: 200_000, moreData: true, elapsedSeconds: 2))
        XCTAssertTrue(d.onSummary(bytesLeft: 1, moreData: true, elapsedSeconds: 3))
    }

    func testStallGuardStopsAfterMaxFlatSummaries() {
        var d = OuraHistoryDrain()
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 1)) // sets the floor
        // Same bytes_left repeated — no progress. Stops on the maxStallSummaries-th flat read.
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 2))  // stall 1
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 3))  // stall 2
        XCTAssertFalse(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 4)) // stall 3 -> stop
    }

    func testStallCounterResetsOnFreshProgress() {
        var d = OuraHistoryDrain()
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 1))
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 2)) // stall 1
        XCTAssertTrue(d.onSummary(bytesLeft: 900, moreData: true, elapsedSeconds: 3))  // progress -> reset
        XCTAssertTrue(d.onSummary(bytesLeft: 900, moreData: true, elapsedSeconds: 4))  // stall 1 again
        XCTAssertTrue(d.onSummary(bytesLeft: 900, moreData: true, elapsedSeconds: 5))  // stall 2 (not stopped)
    }

    func testDeadlineGuardStopsPastMaxDrainSeconds() {
        var d = OuraHistoryDrain()
        XCTAssertTrue(d.onSummary(bytesLeft: 500, moreData: true, elapsedSeconds: 299))
        XCTAssertFalse(d.onSummary(bytesLeft: 400, moreData: true,
                                   elapsedSeconds: OuraHistoryDrain.maxDrainSeconds + 0.1))
    }

    // MARK: stored ring-time → cursor

    func testNoteStoredRingTimeTracksMaxAndIgnoresCorrupt() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(100, resumeCursorAtFetchStart: 0)
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart: 0)
        d.noteStoredRingTime(50, resumeCursorAtFetchStart: 0) // older, doesn't lower the max
        XCTAssertEqual(d.maxStoredRingTime, 3_453_828)
        d.noteStoredRingTime(OuraHistoryDrain.maxPlausibleResumeTicks + 1, resumeCursorAtFetchStart: 0)
        XCTAssertEqual(d.maxStoredRingTime, 3_453_828, "over-ceiling ring-time must be ignored")
        XCTAssertFalse(d.sawPreResumeData)
    }

    func testPreResumeDataFlagsReboot() {
        var d = OuraHistoryDrain()
        // We sought from cursor 1000; a real sample at 500 is OLDER than the seek → ring reset / seek ignored.
        d.noteStoredRingTime(500, resumeCursorAtFetchStart: 1000)
        XCTAssertTrue(d.sawPreResumeData)
    }

    func testFullPullSeekNeverFlagsReboot() {
        var d = OuraHistoryDrain()
        // A full pull seeks from 0 (no floor); early samples must NOT be treated as pre-resume.
        d.noteStoredRingTime(500, resumeCursorAtFetchStart: 0)
        XCTAssertFalse(d.sawPreResumeData)
    }

    // MARK: cursor commit

    func testResumeCursorAdvancesWhenForwardAndResolves() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart: 1000)
        XCTAssertEqual(d.resumeCursorAtDrainEnd(currentCursor: 1000, resolvesUnderAnchor: true), 3_453_828)
    }

    func testResumeCursorUnchangedWhenNotResolving() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart: 1000)
        XCTAssertEqual(d.resumeCursorAtDrainEnd(currentCursor: 1000, resolvesUnderAnchor: false), 1000)
    }

    func testResumeCursorUnchangedWhenNotForward() {
        var d = OuraHistoryDrain()
        // Newest stored sample EQUALS the cursor (no new data past it) — not forward, and not a reboot
        // (a sample strictly BELOW the seek would flag `sawPreResumeData`, tested separately).
        d.noteStoredRingTime(1000, resumeCursorAtFetchStart: 1000)
        XCTAssertFalse(d.sawPreResumeData)
        XCTAssertEqual(d.resumeCursorAtDrainEnd(currentCursor: 1000, resolvesUnderAnchor: true), 1000)
    }

    func testRebootResetsCursorToFullPull() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart: 1000) // forward...
        d.noteStoredRingTime(500, resumeCursorAtFetchStart: 1000)       // ...but also a pre-resume sample
        XCTAssertTrue(d.sawPreResumeData)
        XCTAssertEqual(d.resumeCursorAtDrainEnd(currentCursor: 1000, resolvesUnderAnchor: true), 0,
                       "a reboot forces 0 (full pull) even if a forward sample also arrived")
    }

    // MARK: #2097 - a SyncTime anchor confirming clock continuity overrides the reboot reset

    func testAnchorConfirmsContinuityKeepsCursorInsteadOfFullReset() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(500, resumeCursorAtFetchStart: 1000) // stale sample -> sawPreResumeData
        XCTAssertTrue(d.sawPreResumeData)
        XCTAssertEqual(d.resumeCursorAtDrainEnd(currentCursor: 1000, resolvesUnderAnchor: true,
                                                 anchorConfirmsContinuity: true), 1000,
                       "continuity confirmed (#2097): not a reboot - discard the stale replay, keep the cursor")
    }

    func testAnchorConfirmsContinuityStillAdvancesOnRealForwardProgress() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart: 1000) // forward...
        d.noteStoredRingTime(500, resumeCursorAtFetchStart: 1000)       // ...plus a stale replay
        XCTAssertTrue(d.sawPreResumeData)
        XCTAssertEqual(d.resumeCursorAtDrainEnd(currentCursor: 1000, resolvesUnderAnchor: true,
                                                 anchorConfirmsContinuity: true), 3_453_828,
                       "continuity confirmed: genuine forward progress still commits normally")
    }

    func testAnchorContinuityDefaultsToOldRebootBehaviorWhenOmitted() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(500, resumeCursorAtFetchStart: 1000)
        XCTAssertEqual(d.resumeCursorAtDrainEnd(currentCursor: 1000, resolvesUnderAnchor: true), 0,
                       "omitting anchorConfirmsContinuity must not change today's behavior")
    }

    // MARK: #2097 - anchorsAreContinuous (the SyncTime anchor comparison itself)

    func testAnchorsAreContinuousOnTheReal20260911N2Gap() {
        // The witnessed n=2 occurrence: 12:29:26 -> 14:00:02 local, 5436s wall, 54357 ring ticks
        // (~9.999 ticks/s) spanning the Oura-app handoff. The ring's clock never paused.
        let previous = (ringTicks: UInt32(42_236_951), unixSeconds: Int64(0))
        let current = (ringTicks: UInt32(42_291_308), unixSeconds: Int64(5436))
        XCTAssertTrue(OuraHistoryDrain.anchorsAreContinuous(previous: previous, current: current))
    }

    func testAnchorsAreContinuousDetectsARealPause() {
        // A genuine power-cycle: ticks paused for 821s (matches the measured 13m41s dead-battery
        // reboot) somewhere inside a 3600s wall-clock gap.
        let previous = (ringTicks: UInt32(1_000_000), unixSeconds: Int64(0))
        let tickedSeconds = 3600 - 821
        let current = (ringTicks: UInt32(1_000_000) + UInt32(tickedSeconds * 10), unixSeconds: Int64(3600))
        XCTAssertFalse(OuraHistoryDrain.anchorsAreContinuous(previous: previous, current: current))
    }

    func testAnchorsAreContinuousToleratesOrdinaryJitter() {
        // 5s of receipt-latency noise across an otherwise-continuous gap must not false-positive as a
        // pause (well under anchorContinuityMaxPauseSeconds).
        let previous = (ringTicks: UInt32(1_000_000), unixSeconds: Int64(0))
        let current = (ringTicks: UInt32(1_000_000 + 3_000), unixSeconds: Int64(305)) // 305s wall, 300s ticked
        XCTAssertTrue(OuraHistoryDrain.anchorsAreContinuous(previous: previous, current: current))
    }

    func testAnchorsAreContinuousDeclinesOnTooShortAGap() {
        let previous = (ringTicks: UInt32(1_000_000), unixSeconds: Int64(0))
        let current = (ringTicks: UInt32(1_000_050), unixSeconds: Int64(5)) // below the 10s minimum
        XCTAssertFalse(OuraHistoryDrain.anchorsAreContinuous(previous: previous, current: current),
                       "too short a gap to judge - declines rather than guessing")
    }

    func testAnchorsAreContinuousOnTheReal20260912FastReconnect() {
        // 2026-09-12 19:38:56 -> 19:39:23: an app relaunch (Xcode install), state restoration resumed
        // the still-connected ring, and the next connect came 27s later with a stale replay. Ring
        // ticks 43358625 -> 43358893 = 268 ticks over 27s wall (9.93/s): plainly continuous, but the
        // original 30s floor declined and the old full re-pull from 2026-07-24 fired. Must judge, and
        // must say continuous.
        let previous = (ringTicks: UInt32(43_358_625), unixSeconds: Int64(0))
        let current = (ringTicks: UInt32(43_358_893), unixSeconds: Int64(27))
        XCTAssertTrue(OuraHistoryDrain.anchorsAreContinuous(previous: previous, current: current),
                      "a 27s gap with a continuous ring clock is judgeable and continuous")
    }

    func testAnchorsAreContinuousDeclinesWhenTicksWentBackward() {
        let previous = (ringTicks: UInt32(1_000_000), unixSeconds: Int64(0))
        let current = (ringTicks: UInt32(999_000), unixSeconds: Int64(100)) // never observed; decline, not confirm
        XCTAssertFalse(OuraHistoryDrain.anchorsAreContinuous(previous: previous, current: current))
    }

    // MARK: loaded-cursor sanitize + reset

    func testSanitizeLoadedCursor() {
        XCTAssertEqual(OuraHistoryDrain.sanitizeLoadedCursor(3_453_828), 3_453_828)
        XCTAssertEqual(OuraHistoryDrain.sanitizeLoadedCursor(0), 0)
        XCTAssertEqual(OuraHistoryDrain.sanitizeLoadedCursor(OuraHistoryDrain.maxPlausibleResumeTicks + 1), 0,
                       "a persisted cursor above the ceiling is pre-fix garbage → full pull")
    }

    func testResetClearsState() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart: 1000)
        d.noteStoredRingTime(500, resumeCursorAtFetchStart: 1000)
        d.noteSeenRingTime(3_453_900)
        _ = d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 1)
        d.reset()
        XCTAssertEqual(d.maxStoredRingTime, 0)
        XCTAssertEqual(d.maxSeenRingTime, 0)
        XCTAssertEqual(d.eventsSinceLastRequest, 0)
        XCTAssertFalse(d.sawPreResumeData)
        // Stall floor reset: a fresh flat sequence starts counting from scratch.
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 1))
    }

    // MARK: in-session continuation cursor (open_oura drain_events `progressed`)

    func testContinuationCursorAdvancesPastMaxSeen() {
        var d = OuraHistoryDrain()
        // The 2026-07-12 shape: sought from 1_681_398, batch served records up to rt 3_595_428.
        d.noteSeenRingTime(1_686_000)
        d.noteSeenRingTime(3_595_428)
        d.noteSeenRingTime(2_000_000)   // out-of-order within the batch, doesn't lower the max
        XCTAssertEqual(d.continuationCursor(lastRequestCursor: 1_681_398), 3_595_429,
                       "next request starts one past the newest record served")
    }

    func testContinuationStopsOnEmptyBatch() {
        var d = OuraHistoryDrain()
        XCTAssertNil(d.continuationCursor(lastRequestCursor: 1_681_398),
                     "no records since the last request → no progress → stop, never re-request")
    }

    func testContinuationStopsWhenCursorWouldNotAdvance() {
        var d = OuraHistoryDrain()
        // A re-served window: records arrived but none newer than where we already asked from.
        d.noteSeenRingTime(1_686_000)
        d.noteSeenRingTime(3_595_428)
        XCTAssertNil(d.continuationCursor(lastRequestCursor: 3_595_429),
                     "a batch that only re-serves old records must stop the drain (the 5x re-serve loop)")
    }

    func testContinuationReArmsProgressTestPerRequest() {
        var d = OuraHistoryDrain()
        d.noteSeenRingTime(2_000_000)
        XCTAssertEqual(d.continuationCursor(lastRequestCursor: 1_000_000), 2_000_001)
        // No new records after the advanced request: the next decision is stop, not a re-request at
        // the same cursor.
        XCTAssertNil(d.continuationCursor(lastRequestCursor: 2_000_001))
        // Fresh records past the new cursor re-enable progress.
        d.noteSeenRingTime(2_500_000)
        XCTAssertEqual(d.continuationCursor(lastRequestCursor: 2_000_001), 2_500_001)
    }

    func testSeenRingTimeIgnoresCorruptAndIsIndependentOfStored() {
        var d = OuraHistoryDrain()
        d.noteSeenRingTime(OuraHistoryDrain.maxPlausibleResumeTicks + 1)
        XCTAssertEqual(d.maxSeenRingTime, 0, "over-ceiling ring-time must not steer the continuation")
        // Unanchored records advance the CONTINUATION cursor without touching the durable one: the
        // ring served them (must not re-serve this session), but only anchored stored samples commit.
        d.noteSeenRingTime(3_000_000)
        XCTAssertEqual(d.maxSeenRingTime, 3_000_000)
        XCTAssertEqual(d.maxStoredRingTime, 0)
        d.noteStoredRingTime(2_900_000, resumeCursorAtFetchStart: 0)
        XCTAssertEqual(d.maxStoredRingTime, 2_900_000)
        XCTAssertEqual(d.maxSeenRingTime, 3_000_000, "stored notes don't inflate the seen max")
    }
}
