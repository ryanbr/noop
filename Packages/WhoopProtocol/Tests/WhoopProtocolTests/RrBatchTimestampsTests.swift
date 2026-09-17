import XCTest
@testable import WhoopProtocol

/// Vectors here are duplicated verbatim in Kotlin `RrBatchTimestampsTest` so the twins stay byte-parity.
final class RrBatchTimestampsTests: XCTestCase {

    private func spread(_ ts: Int, _ rrs: [Int]) -> [(ts: Int, rrMs: Int)] {
        RrBatchTimestamps.spread(frameTs: ts, rrMs: rrs)
    }

    func testEmptyArrayStaysEmpty() {
        XCTAssertTrue(spread(1000, []).isEmpty)
    }

    func testSingleIntervalIsUnchanged() {
        // The 5/MG case: a frame arriving at about the beat rate must pass through byte-identical.
        let out = spread(1000, [820])
        XCTAssertEqual(out.map(\.ts), [1000])
        XCTAssertEqual(out.map(\.rrMs), [820])
    }

    func testTwoIntervalsBackDateTheEarlierBeat() {
        // The last interval ends at the frame; the one before it backs off by the 740 ms that follow.
        let out = spread(1000, [740, 740])
        XCTAssertEqual(out.map(\.ts), [999, 1000])
        XCTAssertEqual(out.map(\.rrMs), [740, 740])
    }

    func testThreeIntervalsAccumulateWhatFollows() {
        // 800 after the middle beat -> 1 s; 1600 after the first -> 2 s.
        let out = spread(1000, [800, 800, 800])
        XCTAssertEqual(out.map(\.ts), [998, 999, 1000])
        XCTAssertEqual(out.map(\.rrMs), [800, 800, 800])
    }

    func testOrderAndValuesAreUntouched() {
        let rrs = [700, 900, 650, 1100]
        let out = spread(5000, rrs)
        XCTAssertEqual(out.map(\.rrMs), rrs, "values and their order must survive unchanged")
        XCTAssertEqual(out.map(\.ts).last, 5000, "the most recent interval ends at the frame")
        XCTAssertEqual(out.map(\.ts), out.map(\.ts).sorted(), "timestamps stay oldest-first")
    }

    func testBeatTimeIsNeitherAddedNorRemoved() {
        // The invariant that separates this from every collapse candidate: no beat is added, dropped or
        // altered, so rrCoverage's numerator is identical before and after.
        let rrs = [740, 760, 800, 690, 910]
        XCTAssertEqual(spread(1234, rrs).map(\.rrMs).reduce(0, +), rrs.reduce(0, +))
    }

    func testHalfSecondRoundsUpOnBothPlatforms() {
        // 500 ms after the first beat rounds to 1 s. Kotlin's roundToInt and Swift's rounded() agree
        // here because the accumulator is never negative.
        XCTAssertEqual(spread(1000, [500, 500]).map(\.ts), [999, 1000])
    }

    func testNegativeValueCannotWalkTheClockForwards() {
        // A malformed interval must not push a later beat past the frame timestamp.
        let out = spread(1000, [700, -50, 700])
        XCTAssertEqual(out.map(\.ts).last, 1000)
        XCTAssertTrue(out.map(\.ts).allSatisfy { $0 <= 1000 })
        XCTAssertEqual(out.map(\.ts), out.map(\.ts).sorted())
    }
}
