import XCTest
@testable import Strand
import WhoopStore

/// The sleep detail the coach could not see (#1817), and the normalisation that stops it reading
/// nonsense. Twin of the Kotlin `AiCoachContextTest` cases; the formatters are pure, so this runs
/// headlessly with no repo reads.
@MainActor
final class AICoachSleepContextTests: XCTestCase {

    private func engine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-aicoach-sleep"))
    }

    private func day(deep: Double? = nil, rem: Double? = nil,
                     light: Double? = nil, efficiency: Double? = nil) -> DailyMetric {
        DailyMetric(day: "2026-06-01", totalSleepMin: 450, efficiency: efficiency,
                    deepMin: deep, remMin: rem, lightMin: light, disturbances: nil,
                    restingHr: 52, avgHrv: 65, recovery: 67, strain: 12.3, exerciseCount: nil)
    }

    /// `rest 7.5h` used to be every word the coach got about a night.
    func testStagesReachTheContextLine() {
        let line = engine().dayLine(day(deep: 84, rem: 114, light: 252, efficiency: 0.94))
        XCTAssertTrue(line.contains("deep 1.4h"), line)
        XCTAssertTrue(line.contains("REM 1.9h"), line)
        XCTAssertTrue(line.contains("light 4.2h"), line)
        XCTAssertTrue(line.contains("eff 94%"), line)
    }

    /// A night with no staging says so rather than the field vanishing, so the model cannot read a
    /// missing stage as a zero.
    func testUnstagedNightReportsDashesNotSilence() {
        let line = engine().dayLine(day())
        XCTAssertTrue(line.contains("deep —"), line)
        XCTAssertTrue(line.contains("REM —"), line)
        XCTAssertTrue(line.contains("light —"), line)
        XCTAssertTrue(line.contains("eff —"), line)
    }

    /// Efficiency arrives as a PERCENTAGE on some import paths, which `SleepView` and `StagesCard`
    /// each guard against inline. Without the same guard a bare `* 100` sends "eff 9400%".
    func testEfficiencyStoredAsPercentageIsNotMultipliedAgain() {
        let e = engine()
        XCTAssertEqual(e.efficiencyPercentOrDash(0.94), "94%")
        XCTAssertEqual(e.efficiencyPercentOrDash(94.0), "94%")
        XCTAssertEqual(e.efficiencyPercentOrDash(nil), "—")
        XCTAssertEqual(e.efficiencyPercentOrDash(0), "—")
        // Above a fraction but below the percentage split: not a value this can honestly render.
        XCTAssertEqual(e.efficiencyPercentOrDash(1.2), "—")
    }
}
