import XCTest
@testable import StrandAnalytics

/// Pins the windowed-read planner. Twin of Kotlin `WindowedStreamPlanTest` — same table, same answers.
///
/// Two properties matter here and nothing else does. The walk must collapse to ONE stride of reading per
/// day, which is the whole point; and every case the planner cannot prove safe must land on `.fullRead`,
/// because this sits on the scoring path where an optimisation that guesses produces a wrong number rather
/// than a slow one.
final class WindowedStreamPlanTests: XCTestCase {

    private let day = 86_400
    private let h30 = 108_000
    private let midnight = 1_787_875_200

    /// The real shape: days walked backwards, 54-hour windows on a 24-hour stride. Day 0 reads in full
    /// because nothing is buffered; every day after it extends by EXACTLY one stride, which is the 2.25x
    /// overlap being removed.
    func testBackwardWalkExtendsByExactlyOneStridePerDay() {
        var owner: String?
        var cf = 0, ct = 0
        var plans: [WindowedStreamPlan.Plan] = []
        for offset in 0..<5 {
            let dayStart = midnight - offset * day
            let from = dayStart - h30, to = dayStart + day
            plans.append(WindowedStreamPlan.plan(cachedOwner: owner, cachedFrom: cf, cachedTo: ct,
                                                 cachedTruncated: false, owner: "w", from: from, to: to))
            owner = "w"; cf = from; ct = to
        }
        XCTAssertEqual(plans[0], .fullRead)
        XCTAssertEqual(plans[1], .extend(readFrom: 1_787_680_800, readTo: 1_787_767_199))
        XCTAssertEqual(plans[2], .extend(readFrom: 1_787_594_400, readTo: 1_787_680_799))
        XCTAssertEqual(plans[3], .extend(readFrom: 1_787_508_000, readTo: 1_787_594_399))
        XCTAssertEqual(plans[4], .extend(readFrom: 1_787_421_600, readTo: 1_787_507_999))
        // Each extension is one stride, inclusive at both ends — the store's range predicate is too.
        for p in plans.dropFirst() {
            guard case let .extend(readFrom, readTo) = p else { return XCTFail("expected .extend, got \(p)") }
            XCTAssertEqual(readTo - readFrom + 1, day)
        }
    }

    /// Everything the planner cannot prove safe reads in full — the pre-existing behaviour, unchanged.
    func testUnprovableCasesReadInFull() {
        func p(_ co: String?, _ cf: Int, _ ct: Int, _ trunc: Bool, _ o: String, _ f: Int, _ t: Int)
            -> WindowedStreamPlan.Plan {
            WindowedStreamPlan.plan(cachedOwner: co, cachedFrom: cf, cachedTo: ct,
                                    cachedTruncated: trunc, owner: o, from: f, to: t)
        }
        XCTAssertEqual(p("a", 100, 200, false, "b", 50, 150), .fullRead)
        XCTAssertEqual(p("w", 100, 200, true, "w", 50, 150), .fullRead)
        XCTAssertEqual(p(nil, 0, 0, false, "w", 50, 150), .fullRead)
        XCTAssertEqual(p("w", 100, 200, false, "w", 10, 99), .fullRead)
        XCTAssertEqual(p("w", 100, 200, false, "w", 150, 250), .fullRead)
        XCTAssertEqual(p("w", 200, 100, false, "w", 50, 150), .fullRead)
        XCTAssertEqual(p("w", 100, 200, false, "w", 150, 50), .fullRead)
    }

    /// A day whose window the buffer already covers reads nothing. The boundary case is the one worth
    /// pinning: `to` landing exactly ON the buffer's start still extends only up to the row below it, so the
    /// boundary row is never read twice.
    func testCoveredServesAndBoundaryNeverDoubleReads() {
        func p(_ cf: Int, _ ct: Int, _ f: Int, _ t: Int) -> WindowedStreamPlan.Plan {
            WindowedStreamPlan.plan(cachedOwner: "w", cachedFrom: cf, cachedTo: ct,
                                    cachedTruncated: false, owner: "w", from: f, to: t)
        }
        XCTAssertEqual(p(100, 200, 120, 180), .serve)
        XCTAssertEqual(p(100, 200, 100, 200), .serve)
        XCTAssertEqual(p(100, 200, 50, 150), .extend(readFrom: 50, readTo: 99))
        XCTAssertEqual(p(100, 200, 50, 100), .extend(readFrom: 50, readTo: 99))
    }

    /// The saved-rows line. Twin of Kotlin `logLineShape` — same inputs, same string, and the shape is
    /// pinned because a diagnostic nobody asserts is a diagnostic that can drift into meaning nothing.
    ///
    /// The zero case is the one worth having: a pass where the windows decline entirely must SAY so rather
    /// than simply omit the line, so a reader can tell "the buffer saved nothing" from "the buffer was
    /// never asked".
    func testLogLine() {
        XCTAssertEqual(
            WindowedStreamPlan.logLine(hrRead: 1_000, hrServed: 9_000, hrTruncated: 0,
                                       rrRead: 250, rrServed: 750, rrTruncated: 3),
            "analyzeRecent windows hr[read=1000 served=9000 truncated=0] "
                + "rr[read=250 served=750 truncated=3]")
        XCTAssertEqual(
            WindowedStreamPlan.logLine(hrRead: 0, hrServed: 0, hrTruncated: 0,
                                       rrRead: 0, rrServed: 0, rrTruncated: 0),
            "analyzeRecent windows hr[read=0 served=0 truncated=0] rr[read=0 served=0 truncated=0]")
    }
}
