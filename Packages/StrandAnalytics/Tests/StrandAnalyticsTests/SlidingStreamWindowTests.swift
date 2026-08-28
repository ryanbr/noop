import XCTest
@testable import StrandAnalytics

/// Pins the sliding read buffer against the only contract that matters: for every window, it returns
/// EXACTLY what a direct store read would have returned. Twin of Kotlin `SlidingStreamWindowTest`.
///
/// The test store is a plain sorted array, so "what a direct read would have returned" is computable
/// independently rather than asserted from the implementation's own behaviour — otherwise the test would
/// agree with a wrong splice.
final class SlidingStreamWindowTests: XCTestCase {

    private let day = 86_400
    private let h30 = 108_000
    private let midnight = 1_787_875_200

    private lazy var store: [Int] = Array(stride(from: midnight - 5 * day, through: midnight + day, by: 1))

    private func direct(_ from: Int, _ to: Int, limit: Int = 1_000_000) -> [Int] {
        Array(store.filter { $0 >= from && $0 <= to }.prefix(limit))
    }

    private func window(limit: Int = 1_000_000) -> SlidingStreamWindow<Int> {
        SlidingStreamWindow<Int>(tsOf: { $0 }, limit: limit) { [self] _, f, t in direct(f, t, limit: limit) }
    }

    /// Day 0 reads its whole 54 h window; each later day reads exactly one 24 h stride. Without the buffer
    /// this walk reads 5 x 54 h; the union of all five windows is what it reads instead.
    func testBackwardWalkMatchesDirectReadsAndReadsEachRowOnce() async {
        let w = window()
        for offset in 0..<5 {
            let dayStart = midnight - offset * day
            let from = dayStart - h30, to = dayStart + day
            let got = await w.rows(owner: "owner", from: from, to: to)
            XCTAssertEqual(got, direct(from, to), "window \(offset) must equal a direct read")
        }
        let lastFrom = midnight - 4 * day - h30
        XCTAssertEqual(w.rowsRead, direct(lastFrom, midnight + day).count, "each row read exactly once")
        XCTAssertGreaterThan(w.rowsServed, w.rowsRead / 2, "and most rows came from the buffer")
    }

    func testOwnerFlipFallsBackToADirectRead() async {
        let w = window()
        let from = midnight - h30, to = midnight + day
        _ = await w.rows(owner: "a", from: from, to: to)
        let readAfterFirst = w.rowsRead
        let got = await w.rows(owner: "b", from: from - day, to: to - day)
        XCTAssertEqual(got, direct(from - day, to - day))
        // A different strap cannot reuse the buffer, so this is a full window read, not a stride.
        XCTAssertEqual(w.rowsRead - readAfterFirst, to - from + 1)
    }

    /// A truncated read cannot be sliced, because `ORDER BY ts ASC LIMIT` drops the NEWEST rows — the
    /// buffer would be missing its tail with nothing to say so.
    /// The truncation counter is the one diagnostic here that means a SCORE may be wrong rather than
    /// merely slow, so pin when it moves and when it does not. Twin of the Kotlin case of the same name.
    func testTruncatedReadsCountsOnlyReadsThatLostRows() async {
        let clean = window()
        _ = await clean.rows(owner: "owner", from: midnight - h30, to: midnight + day)
        XCTAssertEqual(clean.truncatedReads, 0, "a read under the cap lost nothing")

        let capped = window(limit: 1_000)
        _ = await capped.rows(owner: "owner", from: midnight - h30, to: midnight + day)
        XCTAssertEqual(capped.truncatedReads, 1, "a read AT the cap dropped its newest rows")
    }

    /// Once a read is truncated the planner refuses to splice at all — `cachedTruncated` is its FIRST
    /// guard — so every later window is a fresh full read. Each of those that is itself at the cap is a
    /// separate lost tail and counts again: the number is windows-that-lost-rows, not passes.
    ///
    /// Deliberately NOT a test of the truncated-extension branch. That branch needs a buffer that is
    /// valid but whose extension overruns the cap, and a truncated read can never leave a valid buffer,
    /// so a uniform backward walk cannot reach it.
    func testEachTruncatedWindowCountsSeparately() async {
        let w = window(limit: 1_000)
        _ = await w.rows(owner: "owner", from: midnight - h30, to: midnight + day)
        let afterFirst = w.truncatedReads
        _ = await w.rows(owner: "owner", from: midnight - day - h30, to: midnight)
        XCTAssertEqual(w.truncatedReads, afterFirst + 1, "one increment per window that lost rows")
    }

    func testTruncatedReadIsNeverSliced() async {
        let limit = 1_000
        let w = window(limit: limit)
        let from = midnight - h30, to = midnight + day
        let first = await w.rows(owner: "owner", from: from, to: to)
        XCTAssertEqual(first.count, limit)
        let next = await w.rows(owner: "owner", from: from - day, to: to - day)
        XCTAssertEqual(next, direct(from - day, to - day, limit: limit))
    }

    /// A gap (the day cache skipped a day) must not splice across the hole.
    func testGapDoesNotSpliceAcrossTheMissingDay() async {
        let w = window()
        _ = await w.rows(owner: "owner", from: midnight - h30, to: midnight + day)
        let skipStart = midnight - 2 * day
        let got = await w.rows(owner: "owner", from: skipStart - h30, to: skipStart + day)
        XCTAssertEqual(got, direct(skipStart - h30, skipStart + day))
    }

    /// A FAILED read must not be cached as if it were an empty range. Twin of Kotlin
    /// `failedReadIsNotCachedAsEmpty`.
    ///
    /// This is the one that bites silently. An empty SUCCESSFUL read is a true statement — there are no
    /// rows in that span — so the next day may splice against it. An empty FAILED read says nothing, and
    /// caching it lets the following day splice against rows nobody fetched: its window would come back
    /// missing everything the buffer claimed to hold, with no error and no log line, and the days built
    /// from it would be scored on inputs that quietly lost hours.
    ///
    /// Reachable on THIS platform in particular: the engine wraps its store reads in `try?`, so a failure
    /// arrives as an empty array unless the reader says otherwise.
    func testFailedReadIsNotCachedAsEmpty() async {
        var failNext = true
        let w = SlidingStreamWindow<Int>(tsOf: { $0 }, limit: 1_000_000) { [self] _, f, t in
            if failNext { failNext = false; return nil }
            return direct(f, t)
        }
        let from = midnight - h30, to = midnight + day
        let first = await w.rows(owner: "owner", from: from, to: to)
        XCTAssertEqual(first, [], "a failed read yields nothing, as it did before the buffer existed")
        // The next day must go back to the store, not splice against a window nobody filled.
        let next = await w.rows(owner: "owner", from: from - day, to: to - day)
        XCTAssertEqual(next, direct(from - day, to - day))
    }
}
