import XCTest
@testable import StrandAnalytics

/// Pins the #1298 clinician-share export: a disclaimer-stamped, non-diagnostic CSV of the
/// descriptive `RhythmScreener` output. Kotlin twin: `RhythmExportTest`.
final class RhythmExportTests: XCTestCase {

    private let summary = RhythmScreener.NightRhythmSummary(
        readableWindows: 2, steadyWindows: 1, occasionalWindows: 1, variedWindows: 0,
        variationRecurred: false, overall: .occasionalEctopy)

    private let steady = RhythmScreener.WindowResult(
        label: .steady, sd1: 24.5, sd2: 60.0, sd1sd2: 0.408, normRmssd: 0.031,
        turningPointRate: 0.62, ectopicFraction: 0.0, nBeats: 72, confidence: .solid,
        agreedAcrossSources: true, poincare: [])

    private let occasional = RhythmScreener.WindowResult(
        label: .occasionalEctopy, sd1: 40.0, sd2: 70.0, sd1sd2: 0.571, normRmssd: 0.05,
        turningPointRate: 0.8, ectopicFraction: 0.03, nBeats: 66, confidence: .building,
        agreedAcrossSources: false, poincare: [])

    func testCsvCarriesDisclaimerSummaryAndPerWindowRows() {
        let csv = RhythmExport.csv(summary: summary,
                                   windows: [steady, occasional, .unreadable(nBeats: 10)])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertTrue(lines[0].hasPrefix("# NOOP Rhythm export"))
        XCTAssertTrue(csv.contains("NOT a diagnosis"))
        XCTAssertTrue(csv.contains(
            "# summary: readableWindows=2 steady=1 occasional=1 varied=0 "
            + "overall=occasionalEctopy variationRecurred=false"))
        XCTAssertTrue(csv.contains(RhythmExport.header))
        XCTAssertTrue(csv.contains("1,72,24.500,60.000,0.408,0.031,0.620,0.000,steady,solid"))
        XCTAssertTrue(csv.contains("2,66,40.000,70.000,0.571,0.050,0.800,0.030,occasionalEctopy,building"))
        // An unreadable window exports EMPTY stat fields, never fabricated zeros.
        XCTAssertTrue(csv.contains("3,10,,,,,,,unreadable,calibrating"))
    }

    func testFormattingPreRoundsSoTheExportCannotDivergeByDevice() {
        // A stat sitting exactly on a 3-decimal half (0.0625) must format identically to Android.
        // Swift/C `%.3f` rounds half-even (0.062), Java half-up (0.063); num() pre-rounds so BOTH
        // land on 0.063. Pins that the same night can't export differently on iPhone vs Android.
        let boundary = RhythmScreener.WindowResult(
            label: .steady, sd1: 0.0625, sd2: 60.0, sd1sd2: 0.408, normRmssd: 0.031,
            turningPointRate: 0.62, ectopicFraction: 0.0, nBeats: 72, confidence: .solid,
            agreedAcrossSources: true, poincare: [])
        let csv = RhythmExport.csv(summary: summary, windows: [boundary])
        XCTAssertTrue(csv.contains(",0.063,"))
    }

    func testExportNamesNoConditionAndCarriesNoVerdict() {
        let csv = RhythmExport.csv(summary: summary, windows: [steady, occasional]).lowercased()
        for banned in ["mobitz", "afib", "atrial fibrillation", "arrhythmia", "block",
                       "consider a clinician", "see a doctor"] {
            XCTAssertFalse(csv.contains(banned), "export must not contain \"\(banned)\"")
        }
    }
}
