import XCTest
@testable import StrandAnalytics

final class SleepDebtTests: XCTestCase {

    /// Three nights at need (8 h = 480 min) → zero balance, three counted nights.
    func testOnTargetNetsToZero() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 480), ("2026-06-02", 480), ("2026-06-03", 480),
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.balanceMin, 0.0, accuracy: 1e-9)
        XCTAssertEqual(l.nightCount, 3)
        XCTAssertFalse(l.isDebt)
        XCTAssertEqual(l.needMin, 480.0, accuracy: 1e-9)
    }

    /// A surplus night offsets a deficit one (ledger nets credits and debits).
    func testSurplusOffsetsDeficit() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 360),   // −120
            ("2026-06-02", 540),   // +60
            ("2026-06-03", 420),   // −60
        ]
        // need 8 h = 480. Σ = −120 + 60 − 60 = −120.
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.balanceMin, -120.0, accuracy: 1e-9)
        XCTAssertTrue(l.isDebt)
        XCTAssertEqual(l.magnitudeMin, 120.0, accuracy: 1e-9)
        XCTAssertEqual(l.nights.map { $0.deltaMin }, [-120, 60, -60])
    }

    /// Nights with no usable sleep are skipped entirely (never zero-filled as debt).
    func testSkipsNoDataNights() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 480),
            ("2026-06-02", nil),     // skipped
            ("2026-06-03", 0),       // skipped (non-positive)
            ("2026-06-04", 420),     // −60
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.nightCount, 2)
        XCTAssertEqual(l.balanceMin, -60.0, accuracy: 1e-9)
        XCTAssertEqual(l.nights.map { $0.day }, ["2026-06-01", "2026-06-04"])
    }

    /// Only the most-recent `window` COUNTED nights are in scope.
    func testWindowCapKeepsMostRecent() {
        // 16 nights, each 60 min UNDER need → each delta −60.
        let series: [(day: String, totalSleepMin: Double?)] = (1...16).map {
            (String(format: "2026-06-%02d", $0), Double(420))
        }
        let l = SleepDebt.ledger(series: series, needHours: 8.0, window: 14)
        XCTAssertEqual(l.nightCount, 14)               // capped
        XCTAssertEqual(l.balanceMin, -840.0, accuracy: 1e-9)   // 14 × −60
        XCTAssertEqual(l.nights.first?.day, "2026-06-03")      // oldest kept
        XCTAssertEqual(l.nights.last?.day, "2026-06-16")       // newest kept
    }

    /// Empty / all-skipped input → empty ledger, zero balance.
    func testEmptyLedger() {
        let l = SleepDebt.ledger(series: [], needHours: 8.0)
        XCTAssertEqual(l.balanceMin, 0.0, accuracy: 1e-9)
        XCTAssertEqual(l.nightCount, 0)
        XCTAssertTrue(l.nights.isEmpty)

        let allNil: [(day: String, totalSleepMin: Double?)] = [("2026-06-01", nil)]
        XCTAssertEqual(SleepDebt.ledger(series: allNil).nightCount, 0)
    }

    /// The default need is AnalyticsEngine.Rest.defaultNeedHours (8 h).
    func testDefaultNeedIsEightHours() {
        let l = SleepDebt.ledger(series: [("2026-06-01", 420)])
        XCTAssertEqual(l.needMin, AnalyticsEngine.Rest.defaultNeedHours * 60.0, accuracy: 1e-9)
        XCTAssertEqual(l.balanceMin, -60.0, accuracy: 1e-9)
    }

    /// Main sleep remains the canonical nightly figure, while a separately-recorded nap
    /// contributes its asleep minutes when the caller prepares the debt series.
    func testNapMinutesAddDebtRepaymentCredit() throws {
        let credited = try XCTUnwrap(SleepDebt.creditedSleepMin(mainSleepMin: 392, napSleepMin: 48))
        XCTAssertEqual(credited, 440, accuracy: 1e-9)
        let l = SleepDebt.ledger(series: [("2026-06-01", credited)], needHours: 8.0)
        XCTAssertEqual(l.balanceMin, -40, accuracy: 1e-9)
    }

    func testNapCreditRequiresMainSleepAndIgnoresNegativeNapMinutes() {
        XCTAssertNil(SleepDebt.creditedSleepMin(mainSleepMin: nil, napSleepMin: 48))
        XCTAssertNil(SleepDebt.creditedSleepMin(mainSleepMin: 0, napSleepMin: 48))
        XCTAssertEqual(SleepDebt.creditedSleepMin(mainSleepMin: 392, napSleepMin: -10), 392.0)
    }

    /// A NEGATIVE EXACT half-tie balance rounds AWAY from zero (−0.05 → −0.1), the documented
    /// `round1` contract the Kotlin mirror must match (audit #6). needMin = 0.1, slept 0.05 →
    /// delta −0.05 exactly → balance −0.1. Kotlin's old `roundToInt()` (half toward +∞) gave
    /// 0.0 on this exact tie — the real divergence this pins shut.
    func testNegativeHalfTieRoundsAwayFromZero() {
        let l = SleepDebt.ledger(series: [("2026-06-01", 0.05)], needHours: 0.1 / 60.0)
        XCTAssertEqual(l.balanceMin, -0.1, accuracy: 1e-9)   // away-from-zero, not 0.0
    }

    /// The symmetric POSITIVE exact half-tie (+0.05 → +0.1), pinned so the sign-aware Kotlin
    /// rounding can't silently regress one direction. needMin = 0, slept 0.05 → delta +0.05.
    func testPositiveHalfTieRoundsAwayFromZero() {
        let l = SleepDebt.ledger(series: [("2026-06-01", 0.05)], needHours: 0.0)
        XCTAssertEqual(l.balanceMin, 0.1, accuracy: 1e-9)
    }

    /// round1 is exercised on the directly-constructed value too, so the rounding mode is
    /// pinned independent of the (slept − need) arithmetic path, both signs + a non-tie.
    func testRound1HalfTiesAwayFromZero() {
        XCTAssertEqual(SleepDebt.round1(-0.05), -0.1, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(0.05), 0.1, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(-0.04), 0.0, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(-0.25), -0.3, accuracy: 1e-9)
    }
}
