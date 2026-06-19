import XCTest
@testable import StrandAnalytics

/// Pure multi-device fusion contract — the Swift half of the Swift↔Kotlin parity gate. The identical
/// fixtures + expected output live in android/.../FusionResolverTest.kt. Covers the spec test plan
/// (docs/superpowers/specs/2026-06-19-v5-local-multi-device-fusion-design.md §Test plan): trust
/// ordering, cross-validation boundaries, conflict-never-merges, single-source degradation, and
/// provenance integrity.
final class FusionResolverTests: XCTestCase {

    // MARK: - 1. Trust ordering ("best signal wins")

    func testStepsBandBeatsStrapEstimate() {
        // A wrist band COUNTS steps (tier 0); the strap only ESTIMATES (tier 3) — the band must win.
        let point = FusionResolver.resolve(metricKey: "steps", inputs: [
            FusionInput(source: .whoopImport, value: 6000),  // strap estimate
            FusionInput(source: .xiaomiBand, value: 8420),   // counts directly
        ])
        XCTAssertEqual(point?.winningSource, .xiaomiBand)
        XCTAssertEqual(point?.value, 8420)
        XCTAssertEqual(point?.contributors.first?.reason, "counts directly")
    }

    func testSleepWhoopBeatsPhoneBuckets() {
        // Imported WHOOP stages (tier 0) beat phone sleep buckets (tier 2).
        let point = FusionResolver.resolve(metricKey: "sleep_total_min", inputs: [
            FusionInput(source: .appleHealth, value: 400),
            FusionInput(source: .whoopImport, value: 432),
        ])
        XCTAssertEqual(point?.winningSource, .whoopImport)
        XCTAssertEqual(point?.value, 432)
        XCTAssertEqual(point?.contributors.first?.reason, "best stager")
    }

    func testRestingHRStrapBeatsPhone() {
        // The strap measures HR directly (tier 0); the phone aggregates it (tier 2).
        let point = FusionResolver.resolve(metricKey: "rhr", inputs: [
            FusionInput(source: .appleHealth, value: 55),
            FusionInput(source: .whoopImport, value: 52),
        ])
        XCTAssertEqual(point?.winningSource, .whoopImport)
        XCTAssertEqual(point?.value, 52)
    }

    func testTieBrokenStablyBySourcePriority() {
        // Two tier-0 step counters (band + phone). The phone has the lower source-priority for steps?
        // No — for steps both are tier 0; the stable tiebreak is sourcePriority: appleHealth (2) <
        // xiaomiBand (4), so Apple wins the tie even though the band is listed first.
        let point = FusionResolver.resolve(metricKey: "steps", inputs: [
            FusionInput(source: .xiaomiBand, value: 8000),
            FusionInput(source: .appleHealth, value: 8100),
        ])
        XCTAssertEqual(point?.winningSource, .appleHealth)
        XCTAssertEqual(point?.value, 8100)
    }

    // MARK: - 2. Cross-validation classification at boundaries

    func testRestingHRAgreeWithinTolerance() {
        // RHR tolerance: agree <= 3 bpm. Winner 52, other 54 → delta 2 → agree.
        let point = FusionResolver.resolve(metricKey: "rhr", inputs: [
            FusionInput(source: .whoopImport, value: 52),
            FusionInput(source: .appleHealth, value: 54),
        ])
        XCTAssertEqual(point?.agreement, .agree)
    }

    func testRestingHRMinorDeltaJustOverAgreeEdge() {
        // Delta 4 (> 3 agree edge, <= 8 minor edge) → minorDelta.
        let point = FusionResolver.resolve(metricKey: "rhr", inputs: [
            FusionInput(source: .whoopImport, value: 52),
            FusionInput(source: .appleHealth, value: 56),
        ])
        XCTAssertEqual(point?.agreement, .minorDelta)
    }

    func testRestingHRConflictBeyondMinorEdge() {
        // Delta 10 (> 8 minor edge) → conflict.
        let point = FusionResolver.resolve(metricKey: "rhr", inputs: [
            FusionInput(source: .whoopImport, value: 52),
            FusionInput(source: .appleHealth, value: 62),
        ])
        XCTAssertEqual(point?.agreement, .conflict)
    }

    func testSleepConflictTwoHoursVsSeven() {
        // 432 min vs 120 min — a gross divergence → conflict (spec's headline example).
        let point = FusionResolver.resolve(metricKey: "sleep_total_min", inputs: [
            FusionInput(source: .whoopImport, value: 432),
            FusionInput(source: .appleHealth, value: 120),
        ])
        XCTAssertEqual(point?.agreement, .conflict)
    }

    func testStepsPercentBandAgree() {
        // Steps tolerance is ±10% agree / ±30% minor. Winner 8000, other 8500 → 6.25% → agree.
        let point = FusionResolver.resolve(metricKey: "steps", inputs: [
            FusionInput(source: .xiaomiBand, value: 8000),
            FusionInput(source: .whoopImport, value: 8500),
        ])
        XCTAssertEqual(point?.winningSource, .xiaomiBand)
        XCTAssertEqual(point?.agreement, .agree)
    }

    func testStepsPercentBandConflict() {
        // Winner 8000, other 14000 → 75% over → conflict.
        let point = FusionResolver.resolve(metricKey: "steps", inputs: [
            FusionInput(source: .xiaomiBand, value: 8000),
            FusionInput(source: .whoopImport, value: 14000),
        ])
        XCTAssertEqual(point?.agreement, .conflict)
    }

    // MARK: - 3. Conflict never silently merges

    func testConflictKeepsBothContributorsWinnerHigherTrust() {
        let point = FusionResolver.resolve(metricKey: "sleep_total_min", inputs: [
            FusionInput(source: .appleHealth, value: 120),
            FusionInput(source: .whoopImport, value: 432),
        ])
        // Winner is the higher-trust source, value is verbatim (NOT an average of 120 & 432 = 276).
        XCTAssertEqual(point?.winningSource, .whoopImport)
        XCTAssertEqual(point?.value, 432)
        XCTAssertEqual(point?.agreement, .conflict)
        XCTAssertEqual(point?.contributors.count, 2)
        // Both contributors retained for the compare sheet.
        XCTAssertTrue(point?.contributors.contains { $0.source == .appleHealth } ?? false)
        XCTAssertTrue(point?.contributors.contains { $0.source == .whoopImport } ?? false)
    }

    // MARK: - 4. Single-source degradation

    func testSingleSourcePassesThroughNoAgreement() {
        let point = FusionResolver.resolve(metricKey: "hrv", inputs: [
            FusionInput(source: .whoopImport, value: 68),
        ])
        XCTAssertEqual(point?.value, 68)
        XCTAssertEqual(point?.winningSource, .whoopImport)
        XCTAssertEqual(point?.agreement, .single)
        XCTAssertEqual(point?.contributors.count, 1)
    }

    func testEmptyInputsYieldNil() {
        XCTAssertNil(FusionResolver.resolve(metricKey: "hrv", inputs: []))
    }

    // MARK: - 5. Provenance integrity

    func testWinningSourceMatchesSuppliedValue() {
        // Three sources; the winner's value must be exactly the value that source supplied.
        let inputs = [
            FusionInput(source: .appleHealth, value: 55),
            FusionInput(source: .noopComputed, value: 53),
            FusionInput(source: .whoopImport, value: 52),
        ]
        let point = FusionResolver.resolve(metricKey: "rhr", inputs: inputs)
        let winner = point!.winningSource
        let suppliedByWinner = inputs.first { $0.source == winner }!.value
        XCTAssertEqual(point?.value, suppliedByWinner)
        XCTAssertEqual(winner, .whoopImport)  // tier 0 vs computed tier 1 vs phone tier 2
    }

    // MARK: - Policy table sanity

    func testStepsTierTable() {
        XCTAssertEqual(MetricArbitrationPolicy.tier(metric: .steps, source: .xiaomiBand), 0)
        XCTAssertEqual(MetricArbitrationPolicy.tier(metric: .steps, source: .whoopImport), 3)
    }

    func testSleepTierTable() {
        XCTAssertEqual(MetricArbitrationPolicy.tier(metric: .sleep, source: .whoopImport), 0)
        XCTAssertEqual(MetricArbitrationPolicy.tier(metric: .sleep, source: .appleHealth), 2)
    }

    func testKeyMapping() {
        XCTAssertEqual(MetricArbitrationPolicy.kind(forKey: "rhr"), .restingHR)
        XCTAssertEqual(MetricArbitrationPolicy.kind(forKey: "asleep_min"), .sleep)
        XCTAssertEqual(MetricArbitrationPolicy.kind(forKey: "sleep_deep_min"), .sleep)
        XCTAssertEqual(MetricArbitrationPolicy.kind(forKey: "steps"), .steps)
        XCTAssertEqual(MetricArbitrationPolicy.kind(forKey: "made_up_key"), .other)
    }
}
