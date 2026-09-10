import Foundation
import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Byte-identity pin for the contextual Coach suggestion chips. The same inputs MUST produce the
/// same chip strings as the Android twin `com.noop.analytics.CoachSuggestionsTest`. Cross-platform
/// parity is the contract; if you change a chip string here, change it there in the same PR.
final class CoachSuggestionsTests: XCTestCase {

    private let fallback = CoachSuggestions.fallback

    /// Build a DailyMetric with only the fields the chip logic reads, everything else nil.
    private func metric(
        day: Int, recovery: Double? = nil, hrv: Double? = nil,
        sleepMin: Double? = nil, strain: Double? = nil
    ) -> DailyMetric {
        DailyMetric(
            day: String(format: "2026-01-%02d", day),
            totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: nil, avgHrv: hrv, recovery: recovery, strain: strain,
            exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil
        )
    }

    // MARK: - No-data fallback

    func testNilTodayReturnsFallback() {
        XCTAssertEqual(CoachSuggestions.suggestions(for: nil, recent: []), fallback)
    }

    func testAllNilFieldsReturnsFallback() {
        let today = metric(day: 10) // all four signals nil
        XCTAssertEqual(CoachSuggestions.suggestions(for: today, recent: []), fallback)
    }

    // MARK: - Charge bands

    func testLowChargeActiveRecoveryChip() {
        let today = metric(day: 10, recovery: 20)
        let chips = CoachSuggestions.suggestions(for: today, recent: [])
        XCTAssertEqual(chips.first, "Active recovery only today — what should I do?")
        XCTAssertEqual(chips.last, "Analyse my sleep")
        XCTAssertTrue(chips.count >= 2 && chips.count <= 4)
    }

    func testMidChargeQualityOverVolumeChip() {
        let today = metric(day: 10, recovery: 50)
        let chips = CoachSuggestions.suggestions(for: today, recent: [])
        XCTAssertEqual(chips.first, "Quality over volume today — plan my session")
    }

    func testHighChargeGreenLightChip() {
        let today = metric(day: 10, recovery: 90)
        let chips = CoachSuggestions.suggestions(for: today, recent: [])
        XCTAssertEqual(chips.first, "Green light — how hard can I push today?")
    }

    func testChargeBoundary34IsMidBand() {
        let today = metric(day: 10, recovery: 34)
        XCTAssertEqual(CoachSuggestions.suggestions(for: today, recent: []).first,
                       "Quality over volume today — plan my session")
    }

    func testChargeBoundary67IsGreenBand() {
        let today = metric(day: 10, recovery: 67)
        XCTAssertEqual(CoachSuggestions.suggestions(for: today, recent: []).first,
                       "Green light — how hard can I push today?")
    }

    // MARK: - HRV trending down

    func testHrvBelowBaselineAddsDownChip() {
        // 30 days of HRV ~60, then today at 45 (< 0.85 * 60 = 51).
        let recent = (1...30).map { metric(day: $0, hrv: 60) }
        let today = metric(day: 31, recovery: 70, hrv: 45)
        let chips = CoachSuggestions.suggestions(for: today, recent: recent)
        XCTAssertTrue(chips.contains("Why is my HRV trending down?"))
    }

    func testHrvAtBaselineDoesNotAddDownChip() {
        let recent = (1...30).map { metric(day: $0, hrv: 60) }
        let today = metric(day: 31, recovery: 70, hrv: 60)
        let chips = CoachSuggestions.suggestions(for: today, recent: recent)
        XCTAssertFalse(chips.contains("Why is my HRV trending down?"))
    }

    func testHrvBaselineExcludesToday() {
        // Today is in `recent` too; it must be excluded from the baseline so a single low day can
        // still register as "down" against the prior baseline.
        var recent = (1...30).map { metric(day: $0, hrv: 60) }
        let today = metric(day: 31, recovery: 70, hrv: 45)
        recent.append(today)
        let chips = CoachSuggestions.suggestions(for: today, recent: recent)
        XCTAssertTrue(chips.contains("Why is my HRV trending down?"))
    }

    // MARK: - Poor sleep

    func testPoorSleepAddsRecoverChip() {
        let today = metric(day: 10, recovery: 70, sleepMin: 300) // 5h
        let chips = CoachSuggestions.suggestions(for: today, recent: [])
        XCTAssertTrue(chips.contains("I slept poorly — how do I recover today?"))
    }

    func testSixHoursIsNotPoor() {
        let today = metric(day: 10, recovery: 70, sleepMin: 360) // exactly 6h
        let chips = CoachSuggestions.suggestions(for: today, recent: [])
        XCTAssertFalse(chips.contains("I slept poorly — how do I recover today?"))
    }

    // MARK: - High strain

    func testHighStrainAddsLoadedChip() {
        let today = metric(day: 10, recovery: 70, strain: 16)
        let chips = CoachSuggestions.suggestions(for: today, recent: [])
        XCTAssertTrue(chips.contains("Have I done enough today, or push more?"))
    }

    func testStrainBelow14DoesNotAddLoadedChip() {
        let today = metric(day: 10, recovery: 70, strain: 13)
        let chips = CoachSuggestions.suggestions(for: today, recent: [])
        XCTAssertFalse(chips.contains("Have I done enough today, or push more?"))
    }

    // MARK: - Cap + stable generic

    func testAllSignalsFireCapsAtFour() {
        let recent = (1...30).map { metric(day: $0, hrv: 60) }
        let today = metric(day: 31, recovery: 20, hrv: 40, sleepMin: 300, strain: 16)
        let chips = CoachSuggestions.suggestions(for: today, recent: recent)
        // charge + hrv + sleep + strain + stable generic = 5 candidates → capped at 4.
        XCTAssertEqual(chips.count, 4)
        // The stable generic is appended last; with the cap at 4, it is the 4th element (the 5th
        // candidate, the strain chip, is dropped). Charge is first.
        XCTAssertEqual(chips.first, "Active recovery only today — what should I do?")
        XCTAssertEqual(chips.last, "Analyse my sleep")
    }

    func testChargeOnlyYieldsChargeAndGeneric() {
        let today = metric(day: 10, recovery: 90)
        let chips = CoachSuggestions.suggestions(for: today, recent: [])
        XCTAssertEqual(chips, ["Green light — how hard can I push today?", "Analyse my sleep"])
    }

    // MARK: - Byte-identity of the fallback list

    func testFallbackListIsCanonical() {
        XCTAssertEqual(fallback, [
            "How's my recovery trending this week?",
            "What should today's training look like?",
            "Analyse my sleep",
            "Why am I run down?",
        ])
    }
}
