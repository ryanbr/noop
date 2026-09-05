import Foundation
import XCTest
@testable import WhoopProtocol

/// R-R batch timestamps (#1118) — twin of the Kotlin `RrBatchTimestampsTest`, same cases, same numbers.
final class RrBatchTimestampsTests: XCTestCase {

    /// The regression. Two ~740 ms beats used to share one second, so a frame deposited ~1.5 s of
    /// beat-time onto 1 s of wall clock and coverage read 1.5. They must now occupy two seconds.
    func testABatchIsSpreadAcrossTheTimeItDescribes() {
        let out = RrBatchTimestamps.spread(frameTs: 1000, rrMs: [740, 745])
        XCTAssertEqual(out.map(\.rrMs), [740, 745], "values are untouched — only timestamps move")
        XCTAssertEqual(out.map(\.ts), [999, 1000])
    }

    /// The most recent interval ends AT the frame; earlier ones are back-dated by what follows them.
    func testTheLastIntervalLandsOnTheFrameTimestamp() {
        let out = RrBatchTimestamps.spread(frameTs: 5000, rrMs: [1000, 1000, 1000])
        XCTAssertEqual(out.map(\.ts), [4998, 4999, 5000])
    }

    /// The property that makes this a fix rather than a trade: the beat-time a batch carries now matches
    /// the wall-clock span it occupies, which IS what rrCoverage measures.
    func testSpanMatchesTheBeatTimeCarried() {
        let rr = [800, 820, 810, 790]
        let out = RrBatchTimestamps.spread(frameTs: 10_000, rrMs: rr)
        let span = out.last!.ts - out.first!.ts
        let carriedSeconds = rr.dropLast().reduce(0, +) / 1000
        XCTAssertEqual(span, carriedSeconds, accuracy: 1)
    }

    /// A strap that does not batch is byte-identical through this — the 5/MG's clean nights must not move.
    func testASingleIntervalIsUnchanged() {
        let out = RrBatchTimestamps.spread(frameTs: 777, rrMs: [812])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].ts, 777)
        XCTAssertEqual(out[0].rrMs, 812)
    }

    func testAnEmptyBatchYieldsNothing() {
        XCTAssertTrue(RrBatchTimestamps.spread(frameTs: 1, rrMs: []).isEmpty)
    }

    /// No beat is invented or dropped — the count and the values survive exactly, in order.
    func testNoBeatIsAddedOrLost() {
        let rr = [700, 1200, 650, 900, 880]
        let out = RrBatchTimestamps.spread(frameTs: 42_000, rrMs: rr)
        XCTAssertEqual(out.map(\.rrMs), rr)
    }

    /// A nonsense value cannot drag a timestamp forwards past the frame.
    func testANegativeValueCannotMoveTimeForwards() {
        let out = RrBatchTimestamps.spread(frameTs: 100, rrMs: [-5000, 800])
        XCTAssertTrue(out.allSatisfy { $0.ts <= 100 })
    }
}
