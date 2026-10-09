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

    /// A hidden token can outlive its marker when the 500-marker cap evicts the oldest night.
    /// Both a re-delete of that window and a repeated delete of a standing marker must list it again.
    @MainActor
    func testFreshDeleteUnhidesStandingAndCapEvictedMarkers() async throws {
        let defaults = UserDefaults.standard
        let keys = [Repository.dismissedSleepDefaultsKey, Repository.hiddenDismissedSleepDefaultsKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let start = 1_000, end = 1_050
        let token = DismissedSleepSpans.token(startTs: start, endTs: end)
        var markers = (1...DismissedSleepSpans.hardCap).map {
            DismissedSleepSpans.token(startTs: $0 * 1_000, endTs: $0 * 1_000 + 50)
        }
        let hidden = DeletedSleepList.hiding(startTs: start, endTs: end, hidden: [], tokens: markers)
        markers = DismissedSleepSpans.adding(startTs: 999_000, endTs: 999_050, to: markers)
        XCTAssertFalse(markers.contains(token), "The cap must actually evict the hidden night's marker")
        XCTAssertEqual(hidden, [token], "The hidden entry survives that eviction")
        // Make room so the old window's next marker sticks, rather than being immediately evicted again.
        markers = DismissedSleepSpans.removing(startTs: 999_000, endTs: 999_050, from: markers)
        defaults.set(markers, forKey: Repository.dismissedSleepDefaultsKey)
        defaults.set(hidden, forKey: Repository.hiddenDismissedSleepDefaultsKey)

        let store = try await WhoopStore.inMemory()
        let source = "test-deleted-sleep"
        let repo = Repository(deviceId: source)
        repo.setStoreForTesting(store)
        let session = CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9,
                                         restingHr: 52, avgHrv: 70, stagesJSON: nil, stagingSparse: true)
        for attempt in 0..<2 {
            _ = try await store.upsertSleepSessions([session], deviceId: source + "-noop")
            let snapshot = await repo.deleteSleepSession(detectedStartTs: start, endTs: end)
            XCTAssertNotNil(snapshot, "The delete must find the stored night")
            XCTAssertTrue(repo.dismissedSleepWindows().contains { $0.start == start && $0.end == end },
                          "Fresh deletion must still suppress re-detection")
            XCTAssertTrue(repo.dismissedSleepManagementWindows().contains { $0.start == start && $0.end == end },
                          "Fresh deletion must show a row to reopen the night (attempt \(attempt))")
            XCTAssertFalse((defaults.stringArray(forKey: Repository.hiddenDismissedSleepDefaultsKey) ?? []).contains(token))
            repo.hideDeletedSleepWindow(startTs: start, endTs: end)
            XCTAssertFalse(repo.dismissedSleepManagementWindows().contains { $0.start == start && $0.end == end })
        }
    }

}
