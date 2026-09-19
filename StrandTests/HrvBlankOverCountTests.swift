import XCTest
@testable import Strand

/// #2335: the HRV tile is blank and NOOP knows exactly why, so it has to say so.
///
/// The #1118 caveat cannot answer this. It decorates a value that IS shown, and the over-count verdict is
/// the very thing that makes `SleepStager.sessionAvgHRV` return nil, so on the night the caveat was
/// written for there is no row left to attach it to. The reported log carries that exact pair
/// (`rrIntegrity=crossSecondOverCount` with `avgHrv=nil`), which is the case pinned first below.
/// Twin of the Kotlin `HrvBlankOverCountTest`, case for case.
final class HrvBlankOverCountTests: XCTestCase {

    private let today = "2026-09-19"

    private func blanked(_ map: [String: Double], todayKey: String? = nil) -> Bool {
        BodyVitalSigns.hrvBlankedByOverCount(hrvOverCountByDay: map, todayKey: todayKey ?? today)
    }

    func testTheReportedShapeIsExplained() {
        XCTAssertTrue(blanked(["2026-09-19": 1]))
    }

    func testNoNightYetIsNotAnOverCount() {
        // A fresh install, or a wearer who has not slept in the strap. The blank is real but it is NOT
        // this cause, and claiming it would send them chasing a fault that is not there (see #2302,
        // which reports the same blank from having no staged night at all).
        XCTAssertFalse(blanked([:]))
    }

    func testACleanLatestNightIsNotExplainedAway() {
        // Older nights over-counted, the most recent one fine: the caption must not blame an over-count
        // that has since stopped happening.
        XCTAssertFalse(blanked(["2026-09-17": 1, "2026-09-18": 1, "2026-09-19": 0]))
    }

    func testOnlyTheNewestNightDecides() {
        XCTAssertTrue(blanked(["2026-09-17": 0, "2026-09-18": 0, "2026-09-19": 1]))
    }

    func testDayKeysCompareChronologicallyAcrossMonthAndYearEnds() {
        // The whole helper rests on `yyyy-MM-dd` sorting lexicographically the way it sorts in time.
        XCTAssertTrue(blanked(["2026-09-30": 0, "2026-10-01": 1], todayKey: "2026-10-01"))
        XCTAssertTrue(blanked(["2026-12-31": 0, "2027-01-01": 1], todayKey: "2027-01-01"))
        XCTAssertFalse(blanked(["2026-09-30": 1, "2026-10-01": 0], todayKey: "2026-10-01"))
    }

    /// Past `Baselines.vitalCarryDays` (7) the tile blanks because the reading went STALE, not because it
    /// was refused, so the over-count must not take the blame. This is also where the two platforms would
    /// drift: Apple loads 14 days of this series and Android loads RECENT_DAYS_CAP, so a helper keyed on
    /// "whatever was loaded" would answer differently for the same wearer.
    func testAStaleOverCountedNightIsNotTheReasonTheTileIsBlank() {
        XCTAssertTrue(blanked(["2026-09-12": 1]), "inside the carry window")
        XCTAssertFalse(blanked(["2026-09-11": 1]), "older than the carry window")
        XCTAssertFalse(blanked(["2026-08-01": 1]), "far older")
    }

    func testTheFlagIsADoubleSoTheGateIsAThreshold() {
        // It round-trips through metricSeries as a Double, so the gate is `>= 0.5`, not `== 1`.
        XCTAssertTrue(blanked(["2026-09-19": 0.5]))
        XCTAssertFalse(blanked(["2026-09-19": 0.49]))
    }
}
