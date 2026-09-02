import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Twin of the Kotlin `SleepStagerHrOnlyAnchorTest`: what anchors the HR-only band, and why it is not
/// the median (#1801).
final class SleepStagerHrOnlyAnchorTests: XCTestCase {

    private func window(_ aC: Int, _ aA: Int, _ aH: Int, _ nC: Int, _ nA: Int, _ nH: Int) -> [HRSample] {
        let t0 = 1_788_300_000
        var hr: [HRSample] = []
        for i in 0..<(aH * 3600) { hr.append(HRSample(ts: t0 + i, bpm: aC + Int(sin(Double(i) / 500.0) * Double(aA)))) }
        for j in 0..<(nH * 3600) {
            hr.append(HRSample(ts: t0 + aH * 3600 + j, bpm: nC + Int(sin(Double(j) / 900.0) * Double(nA))))
        }
        return hr
    }

    private func sleepHours(_ hr: [HRSample], _ baseline: Double) -> Double {
        Double(SleepStager.hrOnlySleepRuns(hr, baseline: baseline)
            .filter { $0.stage == "sleep" }
            .reduce(0) { $0 + ($1.end - $1.start) }) / 3600.0
    }

    func testAnchorIsTenthPercentileNearestRank() {
        let hr = (1...100).map { HRSample(ts: 1_788_300_000 + $0, bpm: $0) }
        XCTAssertEqual(SleepStager.hrOnlyAnchorPercentile, 0.10, accuracy: 1e-9)
        XCTAssertEqual(SleepStager.hrOnlyBaseline(hr)!, 10.0, accuracy: 1e-9)
    }

    /// The regression this file exists for: the median anchor admits over half of any window by
    /// definition, and measured 14.4 h against a truth of 8 on a field-shaped day.
    func testMedianOverDetectsAndPercentileDoesNot() {
        let hr = window(74, 11, 16, 64, 5, 8)
        let median = sleepHours(hr, SleepStager.hrBaseline(hr)!)
        let percentile = sleepHours(hr, SleepStager.hrOnlyBaseline(hr)!)
        XCTAssertGreaterThan(median, 13.0)
        XCTAssertTrue((7.0...9.5).contains(percentile), "was \(percentile)")
        XCTAssertLessThan(percentile, median - 4.0)
    }

    /// Errs toward UNDER-detection: a missed night leaves "No data", an invented one shows a wrong Rest.
    func testLongMultiNightWindowIsUnderReadNotOverRead() {
        let h = sleepHours(window(78, 12, 38, 60, 6, 16), SleepStager.hrOnlyBaseline(window(78, 12, 38, 60, 6, 16))!)
        XCTAssertLessThanOrEqual(h, 16.0, "was \(h)")
        XCTAssertGreaterThanOrEqual(h, 6.0, "was \(h)")
    }

    func testDetectorBandIsASeparateConstantFromTheConfirmationGate() {
        XCTAssertEqual(SleepStager.hrOnlyBandMult, 1.05, accuracy: 1e-9)
        XCTAssertEqual(SleepStager.hrSleepBandMult, 1.05, accuracy: 1e-9)
    }
}
