import XCTest
@testable import StrandImport

/// Pins the account-export ("Export Data" file) lane's resting-HR semantics — the file-import twin of
/// `OuraApiParserDailyTests`. Oura's daily_readiness `contributors.resting_heart_rate` is a 0-100
/// readiness contributor SCORE, not bpm; the real resting HR comes only from a sleep period's
/// `lowest_heart_rate`.
final class OuraExportParserTests: XCTestCase {

    private func bytes(_ s: String) -> Data { s.data(using: .utf8)! }

    /// Regression test (twin of the API-lane fix): a prior bug stored the readiness contributor score
    /// directly as the user's resting HR. With no sleep period in the export, restingHr must stay nil —
    /// never the 0-100 score — while the readiness score itself stays reference-only.
    func testReadinessContributorRhrScoreDoesNotBecomeRestingHr() {
        let json = """
        { "daily_readiness": [ { "day": "2026-01-02", "score": 80,
            "contributors": { "resting_heart_rate": 99 } } ] }
        """
        let (days, _) = OuraExportParser.parse(["export.json": bytes(json)])
        XCTAssertEqual(days.count, 1)
        XCTAssertNil(days.first?.restingHr)
        XCTAssertEqual(days.first?.readinessScore, 80)
    }

    /// A flat `resting_heart_rate` key on the readiness record is the same contributor score in a
    /// flattened shape — it must not land on restingHr either.
    func testFlatReadinessRestingHeartRateKeyDoesNotBecomeRestingHr() {
        let json = """
        { "daily_readiness": [ { "day": "2026-01-02", "score": 80, "resting_heart_rate": 97 } ] }
        """
        let (days, _) = OuraExportParser.parse(["export.json": bytes(json)])
        XCTAssertNil(days.first?.restingHr)
        XCTAssertEqual(days.first?.readinessScore, 80)
    }

    /// Sleep's `lowest_heart_rate` is the sole resting-HR source. The old code let the readiness loop
    /// overwrite the sleep-derived 48 bpm with the contributor score (96 here) whenever both categories
    /// were present — regardless of file iteration order, since the overwrite didn't check for nil.
    func testSleepLowestHeartRateIsTheSoleRestingHrSource() {
        let json = """
        {
          "sleep": [
            { "day": "2026-01-02", "bedtime_start": "2026-01-01T23:00:00+00:00",
              "bedtime_end": "2026-01-02T06:30:00+00:00", "total_sleep_duration": 25200,
              "lowest_heart_rate": 48 } ],
          "daily_readiness": [
            { "day": "2026-01-02", "score": 80,
              "contributors": { "resting_heart_rate": 96 } } ]
        }
        """
        let (days, _) = OuraExportParser.parse(["export.json": bytes(json)])
        let day = days.first { $0.day == "2026-01-02" }
        XCTAssertEqual(day?.restingHr, 48)
        XCTAssertEqual(day?.readinessScore, 80)
    }

    /// The `readiness` category alias (older API-shaped exports) runs through the same loop and must
    /// obey the same rule.
    func testReadinessAliasCategoryDoesNotWriteRestingHr() {
        let json = """
        { "readiness": [ { "day": "2026-01-03", "score": 74,
            "contributors": { "resting_heart_rate": 100 } } ] }
        """
        let (days, _) = OuraExportParser.parse(["export.json": bytes(json)])
        XCTAssertNil(days.first?.restingHr)
        XCTAssertEqual(days.first?.readinessScore, 74)
    }

    // MARK: - Main-session day-rollup selection (file-export lane twin of OuraApiParserSleepTests)
    //
    // Oura can list MULTIPLE sleep sessions for one day (a short nap/fragment alongside the real night).
    // The old per-field `??` fold let whichever session was listed FIRST claim every daily field — and
    // could even MIX fields across two different sessions (a fragment's totalSleepMin + the real night's
    // restingHr). The fix picks the day's `long_sleep` session (else the longer total_sleep_duration) and
    // applies its fields as a UNIT, mirroring OuraApiParser's `dayWinner`.

    /// A fragment listed BEFORE the main sleep for the same day must not win the rollup: the long_sleep
    /// session outranks the short_sleep fragment regardless of array order.
    func testFragmentBeforeMainSessionMainSessionWins() {
        let json = """
        { "sleep": [
            { "day": "2026-02-01", "type": "short_sleep",
              "bedtime_start": "2026-02-01T13:00:00+00:00", "bedtime_end": "2026-02-01T13:20:00+00:00",
              "total_sleep_duration": 900, "lowest_heart_rate": 90 },
            { "day": "2026-02-01", "type": "long_sleep",
              "bedtime_start": "2026-01-31T23:00:00+00:00", "bedtime_end": "2026-02-01T07:00:00+00:00",
              "total_sleep_duration": 25200, "lowest_heart_rate": 48 }
          ] }
        """
        let (days, sleeps) = OuraExportParser.parse(["export.json": bytes(json)])
        XCTAssertEqual(sleeps.count, 2, "both sessions still appear in the sleep list")
        let day = try! XCTUnwrap(days.first { $0.day == "2026-02-01" })
        XCTAssertEqual(day.totalSleepMin, 420, "the main 420-min night, not the 15-min fragment")
        XCTAssertEqual(day.restingHr, 48, "the main night's resting HR, not the fragment's 90")
    }

    /// A day with ONLY a fragment (no long_sleep for that day) keeps the fragment's data rather than
    /// dropping the day entirely — the rank rule only prefers long_sleep when one is actually present.
    func testFragmentOnlyDayKeepsFragment() {
        let json = """
        { "sleep": [
            { "day": "2026-02-02", "type": "short_sleep",
              "bedtime_start": "2026-02-02T13:00:00+00:00", "bedtime_end": "2026-02-02T13:20:00+00:00",
              "total_sleep_duration": 900, "lowest_heart_rate": 90 }
          ] }
        """
        let (days, sleeps) = OuraExportParser.parse(["export.json": bytes(json)])
        XCTAssertEqual(sleeps.count, 1)
        let day = try! XCTUnwrap(days.first { $0.day == "2026-02-02" })
        XCTAssertEqual(day.totalSleepMin, 15)
        XCTAssertEqual(day.restingHr, 90)
    }

    /// No field mixing: when two sessions with an equal `long_sleep` rank compete, the LONGER one wins
    /// and supplies every field as a unit — restingHr and totalSleepMin must come from the SAME session,
    /// never one field from each.
    func testWinningSessionSuppliesAllFieldsAsAUnitNeverMixed() {
        let json = """
        { "sleep": [
            { "day": "2026-02-03", "type": "long_sleep",
              "bedtime_start": "2026-02-02T22:00:00+00:00", "bedtime_end": "2026-02-03T02:00:00+00:00",
              "total_sleep_duration": 14400, "lowest_heart_rate": 70 },
            { "day": "2026-02-03", "type": "long_sleep",
              "bedtime_start": "2026-02-03T03:00:00+00:00", "bedtime_end": "2026-02-03T09:00:00+00:00",
              "total_sleep_duration": 21600, "lowest_heart_rate": 47 }
          ] }
        """
        let (days, _) = OuraExportParser.parse(["export.json": bytes(json)])
        let day = try! XCTUnwrap(days.first { $0.day == "2026-02-03" })
        // The longer (360-min) session wins the tie; its OWN restingHr (47) must land, not the shorter
        // session's 70 and not a mix of the two.
        XCTAssertEqual(day.totalSleepMin, 360)
        XCTAssertEqual(day.restingHr, 47)
    }
}
