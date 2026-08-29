import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// #940: an impossible hand-edit (bed rolled across midnight onto the COMING evening) produced a
/// future-dated, all-awake "phantom" night. It owned the tab's newest day, `mergeDay` returned nil
/// for it (no asleep minutes), and `buildModel` then collapsed the WHOLE Sleep tab to the first-run
/// empty state: every older night hidden and the edit pencil unreachable. The fix degrades that day
/// to the honest stage-less stub the ◀/▶ browse already renders. These pin the pure fallback rule
/// (`SleepView.stubDaySession`): as long as a day has ANY stored block, the tab has a renderable
/// header + a real edit target, so `buildModel` can never blank a non-empty history. Pure (no store,
/// no view mounting). Android twin: SleepPhantomNightFallbackTest.kt.
final class SleepPhantomNightFallbackTests: XCTestCase {

    /// THE #940 PHANTOM: a userEdited row whose corrected window is future-dated and staged as a
    /// single all-wake segment (SleepWindowReclip's deliberate fallback). Detected key stays at the
    /// real 01:06 onset; the hand-set onset moved to tonight 23:00.
    private func phantom(now: Int) -> CachedSleepSession {
        let detected = now - 5 * 3_600            // ~01:06 this morning (detected key, immutable)
        let editedStart = now + 16 * 3_600        // tonight 23:00 (the impossible corrected onset)
        let editedEnd = editedStart + 6 * 3_600   // tomorrow 05:00
        let allWake = "[{\"start\":\(editedStart),\"end\":\(editedEnd),\"stage\":\"wake\"}]"
        return CachedSleepSession(startTs: detected, endTs: editedEnd, efficiency: nil,
                                  restingHr: nil, avgHrv: nil, stagesJSON: allWake,
                                  userEdited: true, startTsAdjusted: editedStart)
    }

    /// The phantom's day still yields a stage-less stub session spanning its (edited) window, so the
    /// hero renders the honest no-stage-data header with the edit affordance targeting the REAL row,
    /// and the screen-level model can never be nil while a day exists.
    func testPhantomDayYieldsStubSession() {
        let now = 1_800_000_000
        let p = phantom(now: now)
        let stub = SleepView.stubDaySession([p])
        XCTAssertNotNil(stub, "#940 regression: a day with a stored block must render a stub, never blank")
        XCTAssertEqual(stub?.startTs, p.effectiveStartTs)
        XCTAssertEqual(stub?.endTs, p.endTs)
        // The stub is presentation-only: no stages to misread as data.
        XCTAssertNil(stub?.stagesJSON)
    }

    /// A day whose main-night selector can't pick (degenerate blocks) still falls back to the first
    /// block: ANY stored block is enough to keep the tab up.
    func testFallsBackToFirstBlockWhenSelectorAbstains() {
        // A zero-width block is degenerate for the timing selector but must still anchor a header.
        let degenerate = CachedSleepSession(startTs: 1_000, endTs: 1_000, efficiency: nil,
                                            restingHr: nil, avgHrv: nil, stagesJSON: nil)
        XCTAssertNotNil(SleepView.stubDaySession([degenerate]))
    }

    /// Only a genuinely EMPTY day list is allowed to produce nothing (the true first-run state).
    func testEmptyDayYieldsNil() {
        XCTAssertNil(SleepView.stubDaySession([]))
    }

    /// End-to-end pure pass of the #940 editor flow: the guard corrects the reporter's exact
    /// cross-midnight roll BEFORE it can create the phantom, so the merge chain never sees it.
    func testGuardPreventsThePhantomAtTheSource() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func d(_ day: Int, _ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 7, day: day, hour: h, minute: m))!
        }
        // Bed seeded 01:06, wake 05:00, user rolls the time wheel to 23:00 with the date stuck on the
        // 2nd, editing at 05:03. The guard lands the bed on the 1st, the evening the user meant.
        let corrected = SleepEditGuard.autoCorrectedBed(
            previousBed: d(2, 1, 6), candidateBed: d(2, 23, 0),
            originalWake: d(2, 5, 0), now: d(2, 5, 3), calendar: cal)
        XCTAssertEqual(corrected, d(1, 23, 0))
        // And had it slipped through anyway, the corrected window would be flagged disjoint (confirm
        // required) and the repository clamp would refuse to persist it.
        let coverage = (Int(d(2, 1, 6).timeIntervalSince1970), Int(d(2, 5, 0).timeIntervalSince1970))
        let phantomWindow = (Int(d(2, 23, 0).timeIntervalSince1970), Int(d(3, 5, 0).timeIntervalSince1970))
        XCTAssertTrue(SleepEditGuard.isDisjoint(newStart: phantomWindow.0, newEnd: phantomWindow.1,
                                                coverageStart: coverage.0, coverageEnd: coverage.1))
        XCTAssertNil(SleepEditGuard.clampedEditWindow(start: phantomWindow.0, end: phantomWindow.1,
                                                      now: Int(d(2, 5, 3).timeIntervalSince1970)))
    }

    // Missing-night honesty: the newest stored night may stay visible, but the status above it must say
    // whether today's night is still moving through sync/analysis or finished without a detection.
    func testFreshnessProgressStatesWinOverStaleHistory() {
        XCTAssertEqual(resolveSleepFreshness(hasCurrentNight: false, morningReady: true, syncing: true,
                                              calculating: true, syncedSinceDayStart: false, syncFailed: true), .syncing)
        XCTAssertEqual(resolveSleepFreshness(hasCurrentNight: false, morningReady: true, syncing: false,
                                              calculating: true, syncedSinceDayStart: true, syncFailed: true), .calculating)
    }

    func testFreshnessDoesNotDeclareMissingBeforeMorningOrForCurrentNight() {
        XCTAssertNil(resolveSleepFreshness(hasCurrentNight: false, morningReady: false, syncing: false,
                                           calculating: false, syncedSinceDayStart: true, syncFailed: false))
        XCTAssertNil(resolveSleepFreshness(hasCurrentNight: true, morningReady: true, syncing: false,
                                           calculating: false, syncedSinceDayStart: true, syncFailed: false))
    }

    func testFreshnessDistinguishesFinishedFailedAndWaiting() {
        XCTAssertEqual(resolveSleepFreshness(hasCurrentNight: false, morningReady: true, syncing: false,
                                              calculating: false, syncedSinceDayStart: true, syncFailed: false), .notDetected)
        XCTAssertEqual(resolveSleepFreshness(hasCurrentNight: false, morningReady: true, syncing: false,
                                              calculating: false, syncedSinceDayStart: false, syncFailed: true), .syncFailed)
        XCTAssertEqual(resolveSleepFreshness(hasCurrentNight: false, morningReady: true, syncing: false,
                                              calculating: false, syncedSinceDayStart: false, syncFailed: false), .awaitingSync)
    }
}
