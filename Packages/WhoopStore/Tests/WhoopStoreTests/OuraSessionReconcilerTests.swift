import XCTest
@testable import WhoopStore

/// #1284 residual 3 — the reconciler on @pipiche38's four measured nights. Byte-identical twin of the
/// Kotlin `OuraSessionReconcilerTest`. Every fixture reproduces the STRUCTURE she measured (overlap /
/// gap / completeness ordering / noon-vs-midnight day), not exact wall-clock, so the assertions are the
/// design claims: option (2) collapses all four nights to one row, the nap stays separate.
final class OuraSessionReconcilerTests: XCTestCase {

    private let tz = 7200 // CEST, the corpus timezone (Europe/Paris, summer)
    // A UTC instant that is a LOCAL midnight (utc + tz is a multiple of 86400), so localTs() reads cleanly.
    private var localMidnightUtc: Int { 86_400 * 20_670 - tz }

    /// Unix seconds for a local wall-clock time on day `d` (days after the reference local midnight).
    private func localTs(_ d: Int, _ h: Int, _ m: Int, _ s: Int) -> Int {
        localMidnightUtc + d * 86_400 + h * 3600 + m * 60 + s
    }

    /// codeCount ~ 30-s epochs, the completeness signal (a fuller drain of the same night has more).
    private func win(_ start: Int, _ end: Int) -> OuraSessionReconciler.SessionWindow {
        .init(startTs: start, endTs: end, codeCount: (end - start) / 30)
    }

    /// Replay a persist ORDER through the reconciler against the growing DB; return the final rows.
    private func simulate(_ order: [OuraSessionReconciler.SessionWindow]) -> [OuraSessionReconciler.SessionWindow] {
        var db: [OuraSessionReconciler.SessionWindow] = []
        for s in order {
            switch OuraSessionReconciler.reconcile(new: s, existing: db) {
            case .insert: db.append(s)
            case .skip: break
            case .replace(let superseded):
                db.removeAll { superseded.contains($0.startTs) }
                db.append(s)
            }
        }
        return db
    }

    private func day(_ ts: Int) -> Int { OuraSessionReconciler.noonAnchoredSleepDay(startTs: ts, tzOffsetSeconds: tz) }
    private func midnightDay(_ ts: Int) -> Int { OuraSessionReconciler.floorDiv(ts + tz, 86_400) }

    // Night 08-12/13 — mode 1 (re-anchor): same hypnogram at 3 onsets, all overlapping.
    func testMode1ReAnchorCollapsesToOneRow() {
        let row1 = win(localTs(0, 4, 40, 55), localTs(0, 6, 50, 55)) // 130 min, fullest
        let row2 = win(localTs(0, 4, 50, 9), localTs(0, 6, 48, 9))   // 118 min
        let row3 = win(localTs(0, 6, 34, 9), localTs(0, 6, 48, 9))   // 14 min
        XCTAssertEqual(day(row1.startTs), day(row2.startTs))
        XCTAssertEqual(day(row1.startTs), day(row3.startTs))
        let db = simulate([row3, row2, row1]) // arrive shortest-first, worst case
        XCTAssertEqual(db.count, 1, "mode-1 must collapse to one row")
        XCTAssertEqual(db.first?.startTs, row1.startTs, "the fullest decode survives")
    }

    // Night 08-13/14 — mode 2 (partial drain): B nested in A, A genuinely fuller.
    func testMode2PartialDrainCompletenessGuardKeepsFuller() {
        let rowA = win(1786657310, 1786657310 + 494 * 60) // 494 min / 988 codes
        let rowB = win(1786657552, 1786657552 + 234 * 60) // 234 min / 468 codes, inside A
        XCTAssertTrue(rowB.startTs >= rowA.startTs - 3600 && rowB.endTs <= rowA.endTs, "B is inside A")
        XCTAssertEqual(simulate([rowB, rowA]).first?.startTs, rowA.startTs)
        XCTAssertEqual(simulate([rowA, rowB]).first?.startTs, rowA.startTs)
        XCTAssertEqual(OuraSessionReconciler.reconcile(new: rowB, existing: [rowA]), .skip)
        XCTAssertEqual(OuraSessionReconciler.reconcile(new: rowA, existing: [rowB]), .replace(supersededStartTs: [rowB.startTs]))
    }

    // Night 08-11/12 — the case against a 30-min grid (starts 6¼ min apart straddle 22:30).
    func testGridStraddleStillCollapsesUnderProximity() {
        let real = win(localTs(0, 22, 26, 14), localTs(1, 7, 6, 14))    // the real session, fuller
        let nested = win(localTs(0, 22, 32, 30), localTs(0, 23, 50, 30)) // 78 min, nested
        XCTAssertTrue((1...3600).contains(nested.startTs - real.startTs))
        XCTAssertEqual(simulate([nested, real]).count, 1)
    }

    // Night 08-10/11 — fragment ENDS before midnight: noon-anchor groups it, wake-day would not.
    func testFragmentEndingBeforeMidnightSharesNoonSleepDayNotWakeDay() {
        let fragment = win(localTs(0, 22, 9, 40), localTs(0, 22, 49, 40)) // ends 22:49, before midnight
        let main = win(localTs(0, 22, 50, 49), localTs(1, 7, 30, 49))
        XCTAssertEqual(day(fragment.startTs), day(main.startTs))
        // The WAKE-day (the day each session ENDS) differs — the wake-day bug the noon anchor fixes.
        XCTAssertNotEqual(midnightDay(fragment.endTs), midnightDay(main.endTs))
        XCTAssertEqual(simulate([fragment, main]).count, 1)
        XCTAssertEqual(simulate([fragment, main]).first?.startTs, main.startTs)
    }

    // Night 08-09 — a real afternoon nap shares the sleep-day with the night but must stay separate.
    func testNapSharesSleepDayButStaysDistinct() {
        let nap = win(localTs(0, 14, 24, 4), localTs(0, 14, 46, 4))     // 22 min afternoon nap
        let night = win(localTs(0, 22, 23, 7), localTs(1, 6, 30, 0))
        XCTAssertEqual(day(nap.startTs), day(night.startTs), "nap and night share the noon-anchored sleep-day")
        XCTAssertEqual(simulate([nap, night]).count, 2)
        XCTAssertEqual(OuraSessionReconciler.reconcile(new: night, existing: [nap]), .insert)
    }

    func testSameConnectionRepeatOfIdenticalWindowIsIdempotent() {
        let s = win(localTs(0, 23, 0, 0), localTs(1, 7, 0, 0))
        XCTAssertEqual(simulate([s, s, s]).count, 1, "re-persisting the exact same window keeps one row")
    }
}
