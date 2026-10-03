import XCTest
import WhoopStore
@testable import Strand

/// The Sleep screen's "Deleted sleep windows" list (#515): every deleted night whose marker stands, newest first,
/// minus the hidden ones — and hiding a row never lifts the marker the detector reads.
final class DeletedSleepListTests: XCTestCase {

    private let night1 = DismissedSleepSpans.token(startTs: 1_000, endTs: 2_000)
    private let night2 = DismissedSleepSpans.token(startTs: 3_000, endTs: 4_000)
    private let night3 = DismissedSleepSpans.token(startTs: 5_000, endTs: 6_000)

    private func starts(_ windows: [(start: Int, end: Int)]) -> [Int] { windows.map(\.start) }

    func testListsEveryMarkerNewestFirst() {
        XCTAssertEqual(starts(DeletedSleepList.visible(tokens: [night2, night1, night3], hidden: [])),
                       [5_000, 3_000, 1_000])
        XCTAssertEqual(starts(DeletedSleepList.visible(tokens: [night1, "junk", "9:3"], hidden: [])), [1_000])
    }

    /// Hidden from the list, still deleted: the detector's windows come from the markers alone.
    func testAHiddenNightLeavesTheListButStaysDeleted() {
        let tokens = [night1, night2, night3]
        let hidden = DeletedSleepList.hiding(startTs: 3_000, endTs: 4_000, hidden: [], tokens: tokens)
        XCTAssertEqual(starts(DeletedSleepList.visible(tokens: tokens, hidden: hidden)), [5_000, 1_000])
        XCTAssertTrue(DismissedSleepSpans.isSuppressed(sessionStart: 3_100, sessionEnd: 3_900,
                                                       windows: DismissedSleepSpans.windows(from: tokens)))
    }

    /// Hiding twice keeps one entry; an entry whose marker is gone (reopened, undone) is dropped, so the hidden list
    /// can never outgrow the markers, and a window with no marker is never recorded.
    func testTheHiddenListOnlyNamesStandingMarkers() {
        let once = DeletedSleepList.hiding(startTs: 1_000, endTs: 2_000, hidden: [], tokens: [night1, night2])
        XCTAssertEqual(DeletedSleepList.hiding(startTs: 1_000, endTs: 2_000, hidden: once, tokens: [night1, night2]),
                       [night1])
        XCTAssertEqual(DeletedSleepList.hiding(startTs: 3_000, endTs: 4_000, hidden: [night1, night3],
                                               tokens: [night1, night2]),
                       [night1, night2])
        XCTAssertEqual(DeletedSleepList.hiding(startTs: 7_000, endTs: 8_000, hidden: [], tokens: [night1]), [])
    }

    /// A night reopened and later deleted again comes back on the list, not hidden from the start.
    func testReopeningClearsItsHiddenEntry() {
        let hidden = DeletedSleepList.unhiding(startTs: 1_000, endTs: 2_000, hidden: [night1, night2])
        XCTAssertEqual(hidden, [night2])
        XCTAssertEqual(starts(DeletedSleepList.visible(tokens: [night1, night2], hidden: hidden)), [1_000])
    }
}
