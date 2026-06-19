import XCTest
@testable import StrandAnalytics

/// EffectRanker — the lag-aware "what moves your Charge" ranker. The oracle for the Android
/// EffectRankerTest; keep the two in lockstep (same fixtures, same numbers).
final class EffectRankerTests: XCTestCase {

    private func ymd(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }

    private func row(_ rows: [RankedEffect], _ behavior: String) -> RankedEffect? {
        rows.first { $0.behavior == behavior }
    }

    /// Deterministic per-calendar-day jitter in {-2,-1,0,1,2} so the with/without groups carry
    /// real within-group spread (a perfectly-constant group yields a pooled SD of 0 and Cohen's d
    /// of 0 by design). Trivially mirrored in Kotlin from the day-of-month.
    private func jitter(_ dayOfMonth: Int) -> Double { Double((dayOfMonth * 7) % 5 - 2) }

    // MARK: - Planted lag-1 effect is found at L=1 and beats L=0/L=2

    /// The outcome the NEXT morning (D+1) after each behaviour day is depressed (≈50) while
    /// every other day sits at baseline (≈70). Behaviour days are spaced 4 apart so each D+1 dip
    /// is clean. The strongest |cohensD| must therefore be at lag 1 ("next morning"), negative,
    /// and it must beat lag 0 and lag 2.
    func testPlantedLag1IsFoundAndWins() {
        var outcome: [String: Double] = [:]
        var behaviorDays: Set<String> = []

        // Anchors Jun 1,5,9,13,17,21 (6, spaced 4 apart so the D+1 dips never collide).
        for i in 0..<6 { behaviorDays.insert(ymd(2026, 6, 1 + 4 * i)) }
        // Dense baseline grid (Jun 1..30, Jul 1..8) at ≈70 with per-day jitter.
        for d in 1...30 { outcome[ymd(2026, 6, d)] = 70 + jitter(d) }
        for d in 1...8 { outcome[ymd(2026, 7, d)] = 70 + jitter(d) }
        // Stamp the next-morning dip (≈50) on each anchor's D+1.
        for i in 0..<6 {
            let dip = 2 + 4 * i   // day-of-month of anchor+1 (2,6,10,14,18,22)
            outcome[ymd(2026, 6, dip)] = 50 + jitter(dip)
        }

        let out = EffectRanker.rank(behaviors: ["Alcohol": behaviorDays],
                                    outcomeByDay: outcome, outcome: "Charge")
        let r = row(out, "Alcohol")
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.lag, 1)                       // the planted lag
        XCTAssertEqual(r!.leadLagText, "next morning")
        XCTAssertLessThan(r!.effect.cohensD, 0)         // next-morning outcome is LOWER
        XCTAssertTrue(r!.effect.significant)
        // The next-morning group really is ≈50 vs a ≈70 baseline (means carry the jitter).
        XCTAssertLessThan(r!.effect.meanWith, 55)
        XCTAssertGreaterThan(r!.effect.meanWithout, 65)

        // Lag 1 must dominate lag 0 and lag 2 in |cohensD|. Read each lag's effect directly via
        // the same internal alignment the engine uses.
        let d1 = abs(r!.effect.cohensD)
        let d0 = abs(effectAtLag(behaviorDays, outcome, 0)!.cohensD)
        let d2 = abs(effectAtLag(behaviorDays, outcome, 2)!.cohensD)
        XCTAssertGreaterThan(d1, d0)
        XCTAssertGreaterThan(d1, d2)
    }

    /// Test-only: the BehaviorEffect at a specific lag, via the engine's own shift alignment.
    private func effectAtLag(_ behaviorDays: Set<String>, _ outcome: [String: Double],
                             _ lag: Int) -> BehaviorEffect? {
        let shifted = EffectRanker.shiftedOutcome(outcome, byLag: lag)
        return BehaviorInsights.effect(behaviorDays: behaviorDays, outcomeByDay: shifted,
                                       behavior: "Alcohol", outcome: "Charge")
    }

    // MARK: - Group gate suppresses thin behaviours

    /// A behaviour logged on only 3 days can never clear min(nWith,nWithout) ≥ 5 at any lag, so
    /// it is dropped entirely (no fabricated row).
    func testThinBehaviourIsDropped() {
        var outcome: [String: Double] = [:]
        var thin: Set<String> = []
        for d in 1...3 {                       // only 3 behaviour days → nWith ≤ 3 < 5
            let day = ymd(2026, 6, d)
            thin.insert(day)
            outcome[day] = 50 + jitter(d)
            outcome[ymd(2026, 6, d + 1)] = 50 + jitter(d + 1)
        }
        for d in 1...8 { outcome[ymd(2026, 7, d)] = 70 + jitter(d) }   // plenty of "without"

        let out = EffectRanker.rank(behaviors: ["Sparse": thin],
                                    outcomeByDay: outcome, outcome: "Charge")
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Ranking order matches BehaviorInsights.rank (significant first, |d| desc, name asc)

    /// Two behaviours, both lag-0 same-day effects, with different effect magnitudes. The bigger
    /// |cohensD| ranks first; a name tiebreak applies only on identical effects.
    func testRankingOrder() {
        var outcome: [String: Double] = [:]
        // "Big": large same-day separation (with ≈ 50, without ≈ 70). Jitter gives real spread.
        var big: Set<String> = []
        for d in 1...6 {
            let day = ymd(2026, 1, d)
            big.insert(day)
            outcome[day] = 50 + jitter(d)
        }
        // "Small": modest same-day separation (with ≈ 66, without ≈ 70).
        var small: Set<String> = []
        for d in 1...6 {
            let day = ymd(2026, 3, d)
            small.insert(day)
            outcome[day] = 66 + jitter(d)
        }
        // Shared "without" baseline at 70 (a block neither behaviour touches at any lag).
        for d in 10...20 { outcome[ymd(2026, 5, d)] = 70 + jitter(d) }

        let out = EffectRanker.rank(behaviors: ["Big": big, "Small": small],
                                    outcomeByDay: outcome, outcome: "Charge")
        XCTAssertEqual(out.map { $0.behavior }, ["Big", "Small"])   // |d| Big > Small
        XCTAssertEqual(row(out, "Big")!.lag, 0)                     // both are same-day effects
        XCTAssertEqual(row(out, "Small")!.lag, 0)
    }

    // MARK: - Confidence tiers from paired-day count

    func testConfidenceTiers() {
        XCTAssertEqual(EffectRanker.confidence(forPairs: 4), .calibrating)  // < gate (5)
        XCTAssertEqual(EffectRanker.confidence(forPairs: 5), .building)     // gate…<10
        XCTAssertEqual(EffectRanker.confidence(forPairs: 9), .building)
        XCTAssertEqual(EffectRanker.confidence(forPairs: 10), .solid)       // ≥ 10
    }

    // MARK: - shiftedOutcome alignment (lag 0 is identity, lag re-keys backward)

    func testShiftedOutcomeAlignment() {
        let outcome: [String: Double] = [ymd(2026, 6, 2): 55, ymd(2026, 6, 3): 60]
        // lag 0 → identity.
        XCTAssertEqual(EffectRanker.shiftedOutcome(outcome, byLag: 0), outcome)
        // lag 1 → the value ON day D moves to key D−1, so behaviour day D pairs with outcome D+1.
        let s1 = EffectRanker.shiftedOutcome(outcome, byLag: 1)
        XCTAssertEqual(s1[ymd(2026, 6, 1)], 55)   // outcome of 06-02 keyed under 06-01
        XCTAssertEqual(s1[ymd(2026, 6, 2)], 60)   // outcome of 06-03 keyed under 06-02
        XCTAssertNil(s1[ymd(2026, 6, 3)])
    }

    // MARK: - sentence appends the lead/lag clause

    func testSentenceAppendsLeadLag() {
        let e = BehaviorEffect(behavior: "Alcohol", outcome: "Charge",
                               meanWith: 50, meanWithout: 70, delta: -20,
                               pctChange: -100.0 * 20.0 / 70.0, nWith: 6, nWithout: 8,
                               cohensD: -2.0, pApprox: 0.001, significant: true)
        let r = RankedEffect(behavior: "Alcohol", outcome: "Charge", lag: 1,
                             effect: e, confidence: .building)
        XCTAssertTrue(r.sentence().hasSuffix("(next morning)."))
    }
}
