import XCTest
@testable import StrandAnalytics

/// Pins the weekly-digest focal sentences byte for byte, so moving them behind `DigestFocalLine` (for the
/// app's localized rendering) cannot change the English text the digest has always shown.
final class WeeklyDigestFocalLineTests: XCTestCase {

    private func days(_ range: ClosedRange<Int>, _ value: (Int) -> Double) -> [String: Double] {
        var out: [String: Double] = [:]
        for d in range { out[String(format: "2026-06-%02d", d)] = value(d) }
        return out
    }

    private func build(_ name: String) -> WeeklyDigest {
        switch name {
        case "chargeUp":
            return WeeklyDigestEngine.build(byMetric: [.charge: days(8...14) { _ in 80 }.merging(days(1...7) { _ in 55 }) { a, _ in a }],
                                            anchorDay: "2026-06-13")
        case "rhrUp":
            return WeeklyDigestEngine.build(byMetric: [.rhr: days(8...14) { _ in 60 }.merging(days(1...7) { _ in 52 }) { a, _ in a }],
                                            anchorDay: "2026-06-13")
        case "steadyRest":
            return WeeklyDigestEngine.build(byMetric: [.charge: days(1...14) { _ in 65 }, .effort: days(1...14) { _ in 63 },
                                                       .rest: days(1...14) { d in d % 2 == 0 ? 84 : 81 }],
                                            anchorDay: "2026-06-13")
        case "steady":
            return WeeklyDigestEngine.build(byMetric: [.charge: days(1...14) { _ in 65 }, .effort: days(1...14) { _ in 63 },
                                                       .rest: days(1...14) { d in d % 2 == 0 ? 95 : 70 }],
                                            anchorDay: "2026-06-13")
        case "currentSparse":
            return WeeklyDigestEngine.build(byMetric: [.charge: days(8...9) { _ in 40 }.merging(days(1...7) { _ in 70 }) { a, _ in a }],
                                            anchorDay: "2026-06-09")
        case "previousSparse":
            return WeeklyDigestEngine.build(byMetric: [.charge: days(8...14) { _ in 60 }.merging(days(6...7) { _ in 70 }) { a, _ in a }],
                                            anchorDay: "2026-06-13")
        case "overreaching":
            return WeeklyDigestEngine.build(byMetric: [.charge: days(1...14) { d in d > 7 ? 40 : 70 },
                                                       .effort: days(1...14) { d in d > 7 ? 80 : 50 }],
                                            anchorDay: "2026-06-13")
        default: fatalError(name)
        }
    }

    /// Captured from the digest BEFORE the focal points were split into `DigestFocalLine` (the same
    /// inputs run against the old string-building code), so a drift in `englishText` fails here.
    static let expected: [(String, [String])] = [
        ("chargeUp", ["Charge is up 45% week over week (avg 80 vs 55), a good sign."]),
        ("rhrUp", ["Resting HR is up 15% week over week (avg 60 vs 52), worth a look."]),
        ("steadyRest", ["A steady week: Rest held even (±1.6 pts) and nothing moved much."]),
        ("steady", ["A steady week: no metric moved meaningfully from last week."]),
        ("currentSparse", ["Only 2 days into this week so far, too early to call a week-over-week trend yet."]),
        ("previousSparse", ["Last week only had 2 days of data, so week-over-week changes are rough, not a trend."]),
        ("overreaching", ["Charge is down 43% week over week (avg 40 vs 70), worth a look.",
                          "Your Effort outpaced your Charge this week: you leaned into the red. Watch for a recovery dip."]),
    ]

    func testFocalPointsAreUnchangedAndMatchTheirLines() {
        for (name, sentences) in Self.expected {
            let d = build(name)
            XCTAssertEqual(d.focalPoints, sentences, name)
            XCTAssertEqual(d.focalLines.map(\.englishText), d.focalPoints, name)
        }
    }

    func testLinesCarryTheValuesTheAppRenders() {
        XCTAssertEqual(build("chargeUp").focalLines,
                       [.mover(metric: .charge, direction: 1, magnitude: .percent(45), goodness: 1,
                               thisAverage: 80, lastAverage: 55)])
        XCTAssertEqual(build("overreaching").focalLines.last, .balance(.overreaching))
        XCTAssertEqual(build("steadyRest").focalLines, [.steadyRest(sd: 1.6)])
        XCTAssertEqual(build("currentSparse").focalLines, [.currentWeekSparse(days: 2)])
        XCTAssertEqual(build("previousSparse").focalLines, [.previousWeekSparse(days: 2)])
        XCTAssertEqual(build("steady").focalLines, [.steady])
    }

    func testAmountMagnitudeKeepsTheOldWording() {
        // The absolute-amount branch (percentage under 1 or undefined), in the old format:
        // "\(round1(delta))" plus " pts" for the unitless scores or " <unit>" otherwise.
        XCTAssertEqual(DigestFocalLine.mover(metric: .hrv, direction: 1, magnitude: .amount(4.5, unit: "ms"),
                                             goodness: 1, thisAverage: 64, lastAverage: 60).englishText,
                       "HRV is up 4.5 ms week over week (avg 64 vs 60), a good sign.")
        XCTAssertEqual(DigestFocalLine.mover(metric: .rest, direction: -1, magnitude: .amount(0.5, unit: ""),
                                             goodness: -1, thisAverage: 80, lastAverage: 81).englishText,
                       "Rest is down 0.5 pts week over week (avg 80 vs 81), worth a look.")
    }

    func testEmptyDigestHasNoLines() {
        let d = WeeklyDigestEngine.emptyDigest(weekStart: "2026-06-08", weekEnd: "2026-06-14")
        XCTAssertTrue(d.focalLines.isEmpty)
        XCTAssertTrue(d.focalPoints.isEmpty)
    }
}
