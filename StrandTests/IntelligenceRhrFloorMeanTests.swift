import XCTest
@testable import Strand

/// Pins the resting-HR strap-log line (#691). NOOP's `restingHr` is the deep-sleep mean HR; the line carries
/// it beside the lowest 5-min bin (`floor`, what NOOP reported until it read ~6 bpm under WHOOP's) and the
/// whole in-bed mean a "sleeping HR" app reports, so a "NOOP reads differently from my other app" report is
/// explainable from the log. `rhrFloorMeanLogLine` is the pure formatter the loop calls; it's tested
/// directly (no store). Mirrors the Android `IntelligenceRhrFloorMeanTest` so the two platforms log
/// byte-identical lines.
@MainActor
final class IntelligenceRhrFloorMeanTests: XCTestCase {

    private typealias IE = IntelligenceEngine

    func testAllThreeStatisticsShipOnOneLine() {
        let bpms = [48, 50, 52, 55, 58, 60, 62]   // mean = 55.0 → "55"
        let line = IE.rhrFloorMeanLogLine(day: "2026-06-12", restingHr: 53, floor: 48, inBedBpms: bpms)
        XCTAssertEqual(line,
            "rhr day=2026-06-12 rhr=53 floor=48 nightMean=55 inBedSamples=7 "
            + "(rhr = deep-sleep mean = NOOP RHR; floor = lowest 5-min bin; mean = whole in-bed span)")
    }

    func testMeanRoundsToNearest() {
        // 50,51,52,54 → 207/4 = 51.75 → rounds to 52 (banker-free .rounded()), matching Kotlin Math.round.
        let line = IE.rhrFloorMeanLogLine(day: "2026-06-13", restingHr: 51, floor: 50, inBedBpms: [50, 51, 52, 54])
        XCTAssertTrue(line.contains("rhr=51 floor=50 nightMean=52 inBedSamples=4"), line)
    }

    func testEmptyInBedAndMissingFloorReadNil() {
        // A resting HR but no HR sample inside a matched session (edge): mean and floor read "nil", not 0,
        // and the line is still emitted so the night stays visible in the log.
        let line = IE.rhrFloorMeanLogLine(day: "2026-06-12", restingHr: 47, floor: nil, inBedBpms: [])
        XCTAssertEqual(line,
            "rhr day=2026-06-12 rhr=47 floor=nil nightMean=nil inBedSamples=0 "
            + "(rhr = deep-sleep mean = NOOP RHR; floor = lowest 5-min bin; mean = whole in-bed span)")
    }

    func testLineCarriesNoEmDash() {
        // House style: never an em-dash in shared text.
        let line = IE.rhrFloorMeanLogLine(day: "2026-06-12", restingHr: 50, floor: 48, inBedBpms: [48, 60])
        XCTAssertFalse(line.contains("—"))
    }
}
