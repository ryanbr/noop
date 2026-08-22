import XCTest
@testable import Strand

/// #1535 follow-up: the Apple step total must reach storage as the SAME integer on both platforms.
///
/// Apple's per-day figures arrive as `Double` and a step total genuinely can be fractional — the
/// aggregator accumulates per source before the winning source's figure is taken, and nothing constrains
/// a source to whole counts. Apple truncated where Android rounded, so one fractional day stored a total
/// one lower on Apple than on Android from the same export.
///
/// Pins the rule rather than the symptom: these are the values Kotlin's `Math.round(it).toInt()` produces
/// for the same inputs.
final class AppleStepsRoundingTests: XCTestCase {

    /// A whole total is unchanged — the common case must not move.
    func testWholeTotalsAreUnchanged() {
        XCTAssertEqual(AppleHealthImport.stepsInt(10_432), 10_432)
        XCTAssertEqual(AppleHealthImport.stepsInt(0), 0)
    }

    /// The regression: truncation lost a step here, so Apple stored 10432 against Android's 10433.
    func testAFractionalTotalRoundsRatherThanTruncating() {
        XCTAssertEqual(AppleHealthImport.stepsInt(10_432.6), 10_433)
        XCTAssertEqual(AppleHealthImport.stepsInt(10_432.4), 10_432)
    }

    /// The half case, where the two languages' rules could have disagreed. Swift's `.rounded()` is
    /// half-away-from-zero and Kotlin's `Math.round` is half-up; they agree for the non-negative values a
    /// step count can take, and this pins that agreement rather than assuming it.
    func testTheHalfCaseMatchesTheKotlinRule() {
        XCTAssertEqual(AppleHealthImport.stepsInt(10_432.5), 10_433)
        XCTAssertEqual(AppleHealthImport.stepsInt(0.5), 1)
    }
}
