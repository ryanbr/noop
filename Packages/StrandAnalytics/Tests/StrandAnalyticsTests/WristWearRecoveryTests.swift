import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class WristWearRecoveryTests: XCTestCase {
    private func hr(_ from: Int, _ to: Int, step: Int = 1, bpm: Int = 60) -> [HRSample] {
        stride(from: from, through: to, by: step).map { HRSample(ts: $0, bpm: bpm) }
    }
    private func event(_ ts: Int, _ off: Bool) -> WhoopEvent {
        WhoopEvent(ts: ts, kind: off ? "WRIST_OFF(10)" : "WRIST_ON(9)", payload: [:])
    }
    private func spans(_ events: [WhoopEvent], _ samples: [HRSample], end: Int = 4000) -> [String] {
        AnalyticsEngine.offWristIntervals(events: events, windowEnd: end, hr: samples)
            .map { "\($0.start):\($0.end)" }
    }

    func testMissingOnEndsAtStartOfSustainedHR() {
        XCTAssertEqual(spans([event(100, true)], hr(1000, 1600)), ["100:1000"])
        XCTAssertEqual(spans([event(100, true)], []), ["100:4000"])
        XCTAssertEqual(spans([], hr(1000, 1600)), [])
    }

    func testPairedEventsStayAuthoritativeEvenWithDenseHR() {
        XCTAssertEqual(spans([event(100, true), event(3000, false)], hr(1000, 3500)), ["100:3000"])
    }

    func testRepeatedOffRestartsEvidenceAndPreservesEarlierPairs() {
        let events = [event(2500, true), event(100, true), event(2000, true), event(500, false)]
        XCTAssertEqual(spans(events, hr(2100, 2900)), ["100:500", "2000:2501"])
        XCTAssertEqual(spans(events, hr(2100, 2700)), ["100:500", "2000:4000"])
    }

    func testFutureSamplesAndEventsCannotCloseCurrentTail() {
        XCTAssertEqual(spans([event(100, true), event(5000, false)], hr(4100, 4500)), ["100:4000"])
        XCTAssertEqual(spans([event(5000, true)], hr(1000, 1600)), [])
    }

    func testFiveMinuteConfirmationAndFiveSecondGapBoundaries() {
        XCTAssertEqual(WristWearRecovery.firstSustainedHR(hr(1000, 1300, step: 5), after: 0, before: 2000), 1000)
        XCTAssertNil(WristWearRecovery.firstSustainedHR(hr(1000, 1299), after: 0, before: 2000))
        XCTAssertNil(WristWearRecovery.firstSustainedHR(hr(1000, 1600, step: 6), after: 0, before: 2000))
        XCTAssertNil(WristWearRecovery.firstSustainedHR(hr(1000, 1300), after: 1000, before: 2000))
        XCTAssertNil(WristWearRecovery.firstSustainedHR(hr(1000, 1300), after: 0, before: 1300))
    }

    func testGapsAndInvalidReadingsResetConfirmation() {
        XCTAssertEqual(WristWearRecovery.firstSustainedHR(hr(1000, 1150) + hr(1200, 1500), after: 0, before: 2000), 1200)
        for invalid in [0, 29, 221, 255] {
            let samples = hr(1000, 1199) + [HRSample(ts: 1200, bpm: invalid)] + hr(1201, 1600)
            XCTAssertEqual(WristWearRecovery.firstSustainedHR(samples, after: 0, before: 2000), 1201)
        }
    }

    func testDuplicatesCannotManufactureCoverageAndInvalidWinsConflict() {
        XCTAssertNil(WristWearRecovery.firstSustainedHR(Array(repeating: HRSample(ts: 1000, bpm: 60), count: 1000), after: 0, before: 2000))
        let samples = hr(1000, 1600) + [HRSample(ts: 1200, bpm: 0)]
        for rows in [samples, Array(samples.reversed())] {
            XCTAssertEqual(WristWearRecovery.firstSustainedHR(rows, after: 0, before: 2000), 1201)
        }
    }

    func testRecoveredNightMatchesControlAndPairedOffStillDropsIt() {
        let start = 2 * 3600, end = start + 90 * 60
        let gravity = stride(from: start, through: end, by: 5).map {
            GravitySample(ts: $0, x: 0, y: 0, z: 1, unit: "g")
        }
        let samples = hr(start - 900, end, step: 5, bpm: 50)
        let control = SleepStager.detectSleep(hr: samples, gravity: gravity)
        XCTAssertEqual(control.count, 1)
        let recovered = AnalyticsEngine.offWristIntervals(events: [event(start - 1800, true)], windowEnd: end + 1, hr: samples)
        let actual = SleepStager.detectSleep(hr: samples, gravity: gravity, wristOff: recovered)
        XCTAssertEqual(actual.map { $0.start }, control.map { $0.start })
        XCTAssertEqual(actual.map { $0.end }, control.map { $0.end })
        let paired = AnalyticsEngine.offWristIntervals(events: [event(start - 1800, true), event(end, false)], windowEnd: end + 1, hr: samples)
        XCTAssertTrue(SleepStager.detectSleep(hr: samples, gravity: gravity, wristOff: paired).isEmpty)
    }

    func testRecoveryDoesNotDisableSubsequentHRGapGuard() {
        let samples = hr(100, 1000) + hr(8000, 9000)
        let off = AnalyticsEngine.offWristIntervals(events: [event(0, true)], windowEnd: 10000, hr: samples)
        let period = SleepStager.Period(stage: "sleep", start: 2000, end: 7000)
        XCTAssertEqual(SleepStager.offWristFraction(period, hr: samples, wristOff: off), 1)
    }

    // Swift oracle output is pinned verbatim in the Kotlin twin. Offsets and input cadence vary;
    // neither fixtures nor expected values contain a wearer's recorded samples or timestamps.
    func testParityOracle() {
        var values: [String] = []
        for offset in [0, 86400, 1700000000] {
            for step in [1, 5, 6, 60] {
                for duration in [299, 300, 600] {
                    let result = WristWearRecovery.firstSustainedHR(
                        hr(offset + 100, offset + 100 + duration, step: step), after: offset, before: offset + 1000)
                    values.append(result.map(String.init) ?? "nil")
                }
            }
        }
        let oracle = values.joined(separator: ",")
        print("WRIST_ORACLE=\(oracle)")
        XCTAssertEqual(oracle, "nil,100,100,nil,100,100,nil,nil,nil,nil,nil,nil,nil,86500,86500,nil,86500,86500,nil,nil,nil,nil,nil,nil,nil,1700000100,1700000100,nil,1700000100,1700000100,nil,nil,nil,nil,nil,nil")
    }
}
