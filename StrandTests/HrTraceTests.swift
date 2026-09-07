import XCTest

/// Swift twin of the Kotlin `HrTraceTest` (#1957).
///
/// These exist to keep the two platforms reading the same heart, not merely to check Swift. Every case
/// below has a Kotlin counterpart asserting the same thing, so a change to the retention rule, the tick
/// choices or the normalisation that lands on one side alone fails here.
///
/// The degenerate cases carry the weight, because they are ordinary on a home screen rather than exotic:
/// a widget added mid-afternoon has one point, and a resting arm holds one bpm for minutes.
final class HrTraceTests: XCTestCase {

    private func series(_ pairs: [(Int64, Int)]) -> [HrPoint] {
        pairs.map { HrPoint(ts: $0.0, bpm: $0.1) }
    }

    // MARK: retention

    func testOnePointPerMinuteBucketNewestWins() {
        var s = HrTrace.append([], ts: 600, bpm: 60)
        s = HrTrace.append(s, ts: 620, bpm: 64)   // same bucket
        s = HrTrace.append(s, ts: 660, bpm: 70)   // next bucket
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].bpm, 64)              // newest within the bucket won
        XCTAssertEqual(s[0].ts, 600)              // stamped at the bucket, not the sample
        XCTAssertEqual(s[1].bpm, 70)
    }

    /// The headline number is the latest bpm; a trace ending on an average would disagree with it.
    func testLastPointEqualsLatestReading() {
        var s: [HrPoint] = []
        for i in 0...5 { s = HrTrace.append(s, ts: 600 + Int64(i) * 60, bpm: 60 + i) }
        XCTAssertEqual(HrTrace.stats(s)?.latest, 65)
        XCTAssertEqual(s.last?.bpm, 65)
    }

    func testReadingsOlderThanTheWindowFallOff() {
        let now: Int64 = 100_000
        let s = series([(now - HrTrace.windowSec - 60, 50), (now - 60, 70)])
        let kept = HrTrace.prune(s, nowSec: now)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].bpm, 70)
    }

    /// A clock that jumps backwards must not grow the series without bound.
    func testPointCapHoldsUnderABackwardsClock() {
        var s: [HrPoint] = []
        for i in 0..<(HrTrace.maxPoints + 50) {
            s = HrTrace.append(s, ts: Int64(i) * 60, bpm: 60, nowSec: 0)
        }
        XCTAssertLessThanOrEqual(s.count, HrTrace.maxPoints)
    }

    func testNonPositiveBpmIsNotRecorded() {
        XCTAssertTrue(HrTrace.append([], ts: 600, bpm: 0).isEmpty)
    }

    // MARK: geometry

    func testPointsSpanTheBoxAndFlipBpmUpward() {
        let pts = HrTrace.points(series([(0, 60), (60, 80)]), width: 100, height: 50)
        XCTAssertEqual(pts[0].x, 0, accuracy: 0.001)
        XCTAssertEqual(pts[1].x, 100, accuracy: 0.001)
        XCTAssertEqual(pts[0].y, 50, accuracy: 0.001)   // the LOW bpm sits at the BOTTOM
        XCTAssertEqual(pts[1].y, 0, accuracy: 0.001)
    }

    /// A resting arm holds one bpm for minutes. Zero range must not divide, and must not read as a
    /// flatlined or maxed-out heart, so the line runs along the middle.
    func testFlatSeriesDrawsDownTheMiddle() {
        let pts = HrTrace.points(series([(0, 60), (60, 60), (120, 60)]), width: 90, height: 40)
        XCTAssertEqual(pts.count, 3)
        for p in pts { XCTAssertEqual(p.y, 20, accuracy: 0.001) }
    }

    /// A widget added mid-afternoon has exactly one point until the next minute ticks.
    func testSinglePointSitsAtTheLeftEdge() {
        let pts = HrTrace.points(series([(600, 61)]), width: 100, height: 50)
        XCTAssertEqual(pts.count, 1)
        XCTAssertEqual(pts[0].x, 0, accuracy: 0.001)
        XCTAssertFalse(pts[0].y.isNaN)
    }

    func testEmptySeriesOrZeroBoxDrawsNothing() {
        XCTAssertTrue(HrTrace.points([], width: 100, height: 50).isEmpty)
        XCTAssertTrue(HrTrace.points(series([(0, 60)]), width: 0, height: 50).isEmpty)
        XCTAssertTrue(HrTrace.points(series([(0, 60)]), width: 100, height: 0).isEmpty)
    }

    // MARK: ticks

    func testBpmTicksRunMaxMiddleMin() {
        XCTAssertEqual(HrTrace.bpmTicks(HrTrace.Stats(min: 59, max: 84, latest: 69)), [84, 72, 59])
    }

    /// Three copies of one number is the honest reading of a steady heart. The VIEW declines to draw a
    /// scale in that case; the rule stays here so both platforms agree on what the labels would be.
    func testFlatSeriesLabelsOneNumberThreeTimes() {
        XCTAssertEqual(HrTrace.bpmTicks(HrTrace.Stats(min: 60, max: 60, latest: 60)), [60, 60, 60])
    }

    func testTimeTicksAnchorToTheDataNotTheWindow() {
        XCTAssertEqual(HrTrace.timeTicks(series([(1_000, 60), (1_600, 62), (2_200, 64)])),
                       [1_000, 1_600, 2_200])
    }

    func testTimeTicksDegradeWithoutEnoughSpan() {
        XCTAssertEqual(HrTrace.timeTicks([]), [])
        XCTAssertEqual(HrTrace.timeTicks(series([(600, 60)])), [600])
        XCTAssertEqual(HrTrace.timeTicks(series([(600, 60), (601, 61)])), [600, 601])
    }

    func testStatsOverAnEmptySeriesIsNil() {
        XCTAssertNil(HrTrace.stats([]))
    }

    // MARK: the publish gate that keeps the trace alive

    /// `renderedContentChanged` compares bpm, not history, so a steady heart produced no publish and
    /// therefore no new point — the trace would stop advancing at rest and prune to empty. This is the
    /// rule that asks for a write anyway, and it must fire exactly when a new minute bucket opens.
    func testTraceNeedsPointWhenTheBucketRolls() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var snap = WidgetSnapshot(recovery: nil, bpm: 70, batteryPct: nil, bonded: true, updated: base)
        snap.hrSeries = [HrPoint(ts: Int64(base.timeIntervalSince1970), bpm: 70)]

        XCTAssertFalse(WidgetSnapshot.traceNeedsPoint(previous: snap, bpm: 70, now: base.addingTimeInterval(5)),
                       "same bucket needs nothing")
        XCTAssertTrue(WidgetSnapshot.traceNeedsPoint(previous: snap, bpm: 70, now: base.addingTimeInterval(61)),
                      "a new bucket wants its point even though bpm is unchanged")
    }

    func testTraceNeedsNoPointWithoutAReading() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(WidgetSnapshot.traceNeedsPoint(previous: nil, bpm: nil, now: now))
        XCTAssertFalse(WidgetSnapshot.traceNeedsPoint(previous: nil, bpm: 0, now: now))
        XCTAssertTrue(WidgetSnapshot.traceNeedsPoint(previous: nil, bpm: 70, now: now),
                      "no stored series at all means the first reading is wanted")
    }


    // MARK: the age rule on the headline number

    /// Twin of the Kotlin `HrDisplay`. Without it the card contradicted itself once the trace began
    /// pruning: an empty chart under a confident number, from a reading hours old.
    func testAFreshReadingIsShownAndNotDimmed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let r = HrDisplay.resolve(bpm: 70, newestPointTs: Int64(now.timeIntervalSince1970) - 30, now: now)
        XCTAssertEqual(r.bpm, 70)
        XCTAssertFalse(r.stale)
    }

    func testACarriedReadingIsShownButDimmed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ts = Int64(now.timeIntervalSince1970 - HrDisplay.liveWindow - 30)
        let r = HrDisplay.resolve(bpm: 70, newestPointTs: ts, now: now)
        XCTAssertEqual(r.bpm, 70)
        XCTAssertTrue(r.stale, "past the live window it is carried over, not current")
    }

    func testAnAncientReadingIsDroppedEntirely() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ts = Int64(now.timeIntervalSince1970 - HrDisplay.staleCap - 60)
        XCTAssertNil(HrDisplay.resolve(bpm: 70, newestPointTs: ts, now: now).bpm)
    }

    /// A widget added this minute has a reading and an empty series. Treating that as stale would blank
    /// a widget at the moment it started working.
    func testAFirstReadingWithNoTraceYetIsShown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let r = HrDisplay.resolve(bpm: 70, newestPointTs: nil, now: now)
        XCTAssertEqual(r.bpm, 70)
        XCTAssertFalse(r.stale)
    }

    func testNoReadingShowsNothing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(HrDisplay.resolve(bpm: nil, newestPointTs: nil, now: now).bpm)
        XCTAssertNil(HrDisplay.resolve(bpm: 0, newestPointTs: nil, now: now).bpm)
    }
}
