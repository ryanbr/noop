import XCTest
@testable import StrandAnalytics

final class BehaviorInsightsTests: XCTestCase {

    // MARK: - effect core computation

    func testEffectMeansDeltaAndSign() {
        // With-days outcome mean 60.5, without-days mean 70.125 → delta -9.625,
        // pct ≈ -13.7255%. Behavior lowers the outcome → negative delta & cohensD.
        let outcome: [String: Double] = [
            "d01": 60, "d02": 62, "d03": 58, "d04": 61, "d05": 59, "d06": 63,   // with
            "d07": 70, "d08": 72, "d09": 68, "d10": 71, "d11": 69, "d12": 73,   // without
            "d13": 70, "d14": 68,
        ]
        let behaviorDays: Set<String> = ["d01", "d02", "d03", "d04", "d05", "d06"]
        let e = BehaviorInsights.effect(behaviorDays: behaviorDays, controlDays: Set(outcome.keys).subtracting(behaviorDays), outcomeByDay: outcome,
                                        behavior: "Alcohol", outcome: "Recovery")!
        XCTAssertEqual(e.nWith, 6)
        XCTAssertEqual(e.nWithout, 8)
        XCTAssertEqual(e.meanWith, 60.5, accuracy: 1e-9)
        XCTAssertEqual(e.meanWithout, 70.125, accuracy: 1e-9)
        XCTAssertEqual(e.delta, -9.625, accuracy: 1e-9)
        XCTAssertEqual(e.pctChange!, -13.725490196078432, accuracy: 1e-9)
        XCTAssertLessThan(e.cohensD, 0)                  // lower outcome → negative
        XCTAssertEqual(e.cohensD, -5.247290322400142, accuracy: 1e-6)
        XCTAssertTrue(e.significant)                     // big separation, n≥5 both sides
    }

    func testEffectPositiveDirection() {
        // Behavior RAISES the outcome → positive delta.
        let outcome: [String: Double] = [
            "a": 80, "b": 82, "c": 78, "d": 81, "e": 79,   // with (mean 80)
            "f": 70, "g": 72, "h": 68, "i": 71, "j": 69,   // without (mean 70)
        ]
        let e = BehaviorInsights.effect(behaviorDays: ["a", "b", "c", "d", "e"],
                                        controlDays: Set(outcome.keys).subtracting(["a", "b", "c", "d", "e"]),
                                        outcomeByDay: outcome,
                                        behavior: "Meditation", outcome: "Recovery")!
        XCTAssertEqual(e.delta, 10.0, accuracy: 1e-9)
        XCTAssertGreaterThan(e.cohensD, 0)
        XCTAssertEqual(e.pctChange!, 100.0 * 10.0 / 70.0, accuracy: 1e-9)
        XCTAssertTrue(e.significant)
    }

    func testEffectNilWhenOneGroupEmpty() {
        // Behavior logged every day → no "without" group.
        let outcome: [String: Double] = ["a": 60, "b": 61, "c": 62]
        XCTAssertNil(BehaviorInsights.effect(behaviorDays: ["a", "b", "c"],
                                             controlDays: Set(outcome.keys).subtracting(["a", "b", "c"]),
                                             outcomeByDay: outcome,
                                             behavior: "X", outcome: "Recovery"))
        // Behavior never logged → no "with" group.
        XCTAssertNil(BehaviorInsights.effect(behaviorDays: [],
                                             controlDays: Set(outcome.keys).subtracting([]),
                                             outcomeByDay: outcome,
                                             behavior: "X", outcome: "Recovery"))
    }

    func testEffectIgnoresBehaviorDaysWithNoOutcome() {
        // "z" is in behaviorDays but has no outcome value → not counted in nWith.
        let outcome: [String: Double] = ["a": 60, "b": 62, "c": 70, "d": 72]
        let e = BehaviorInsights.effect(behaviorDays: ["a", "b", "z"],
                                        controlDays: Set(outcome.keys).subtracting(["a", "b", "z"]),
                                        outcomeByDay: outcome,
                                        behavior: "X", outcome: "Recovery")!
        XCTAssertEqual(e.nWith, 2)        // a, b only
        XCTAssertEqual(e.nWithout, 2)     // c, d
    }

    // MARK: - significance flips

    func testSignificanceFlipsWithGroupSize() {
        // SAME clear separation (≈60 vs ≈70), but only 4 days per group → even
        // with a tiny p-value the min-group guard (≥5) blocks significance.
        let smallOutcome: [String: Double] = [
            "w1": 60, "w2": 61, "w3": 59, "w4": 60,
            "o1": 70, "o2": 71, "o3": 69, "o4": 70,
        ]
        let small = BehaviorInsights.effect(behaviorDays: ["w1", "w2", "w3", "w4"],
                                            controlDays: Set(smallOutcome.keys).subtracting(["w1", "w2", "w3", "w4"]),
                                            outcomeByDay: smallOutcome,
                                            behavior: "X", outcome: "Recovery")!
        XCTAssertLessThan(small.pApprox, 0.05)       // strong evidence numerically…
        XCTAssertEqual(Swift.min(small.nWith, small.nWithout), 4)
        XCTAssertFalse(small.significant)            // …but n too small → not flagged

        // Add a 5th day per group with the same separation → now significant.
        let bigOutcome: [String: Double] = [
            "w1": 60, "w2": 61, "w3": 59, "w4": 60, "w5": 60,
            "o1": 70, "o2": 71, "o3": 69, "o4": 70, "o5": 70,
        ]
        let big = BehaviorInsights.effect(behaviorDays: ["w1", "w2", "w3", "w4", "w5"],
                                          controlDays: Set(bigOutcome.keys).subtracting(["w1", "w2", "w3", "w4", "w5"]),
                                          outcomeByDay: bigOutcome,
                                          behavior: "X", outcome: "Recovery")!
        XCTAssertEqual(Swift.min(big.nWith, big.nWithout), 5)
        XCTAssertTrue(big.significant)
    }

    func testSignificanceFlipsWithSeparation() {
        // Big groups but NO real separation (heavily overlapping) → not significant.
        let outcome: [String: Double] = [
            "w1": 65, "w2": 71, "w3": 60, "w4": 75, "w5": 66, "w6": 70,
            "o1": 64, "o2": 72, "o3": 61, "o4": 74, "o5": 67, "o6": 69,
        ]
        let e = BehaviorInsights.effect(behaviorDays: ["w1", "w2", "w3", "w4", "w5", "w6"],
                                        controlDays: Set(outcome.keys).subtracting(["w1", "w2", "w3", "w4", "w5", "w6"]),
                                        outcomeByDay: outcome,
                                        behavior: "X", outcome: "Recovery")!
        XCTAssertGreaterThan(e.pApprox, 0.05)    // no separation → weak evidence
        XCTAssertFalse(e.significant)
    }

    // MARK: - ranking

    func testRankOrdersByEffectSizeSignificantFirst() {
        // Three behaviors over a shared outcome series of 12 days.
        let outcome: [String: Double] = [
            "d1": 50, "d2": 52, "d3": 48, "d4": 51, "d5": 49, "d6": 53,
            "d7": 70, "d8": 72, "d9": 68, "d10": 71, "d11": 69, "d12": 73,
        ]
        // Strong: cleanly splits the low half (d1..d6) vs high half → big |d|, significant.
        let strong: Set<String> = ["d1", "d2", "d3", "d4", "d5", "d6"]
        // Weak: a scattered 3-day set, small + not enough per-group for significance.
        let weak: Set<String> = ["d1", "d7", "d2"]
        // Tiny-but-significant-impossible: 2 days only.
        let tiny: Set<String> = ["d3", "d9"]

        // Predates the Yes/No split and tests the ranking math, so it keeps its original partition
        // by declaring the complement as controls explicitly.
        let all = Set(outcome.keys)
        let ranked = BehaviorInsights.rank(behaviors: ["Strong": strong, "Weak": weak, "Tiny": tiny],
                                           controls: ["Strong": all.subtracting(strong),
                                                      "Weak": all.subtracting(weak),
                                                      "Tiny": all.subtracting(tiny)],
                                           outcomeByDay: outcome, outcome: "Recovery")
        XCTAssertEqual(ranked.count, 3)
        XCTAssertEqual(ranked.first?.behavior, "Strong")   // significant + largest |d|
        XCTAssertTrue(ranked.first!.significant)
        // Non-significant entries trail the significant one.
        XCTAssertFalse(ranked[1].significant)
        XCTAssertFalse(ranked[2].significant)
        // Among the non-significant, larger |cohensD| comes first.
        XCTAssertGreaterThanOrEqual(abs(ranked[1].cohensD), abs(ranked[2].cohensD))
    }

    func testRankDropsUncomputableBehaviors() {
        let outcome: [String: Double] = ["a": 60, "b": 62, "c": 70, "d": 72]
        // "AllDays" covers every day → no without group → dropped.
        // Predates the Yes/No split and tests the ranking math, so it keeps its original partition
        // by declaring the complement as controls explicitly.
        let all = Set(outcome.keys)
        let ranked = BehaviorInsights.rank(behaviors: [
            "AllDays": ["a", "b", "c", "d"],
            "Half": ["a", "b"],
        ], controls: [
            "AllDays": all.subtracting(["a", "b", "c", "d"]),
            "Half": all.subtracting(["a", "b"]),
        ], outcomeByDay: outcome, outcome: "Recovery")
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.behavior, "Half")
    }

    // MARK: - sentence

    func testSentenceLowerWithPercent() {
        // Integer means avoid half-rounding ambiguity: with=60, without=80 →
        // delta -20, pct -25% → "25% lower (avg 60 vs 80, n=5 vs 5)".
        let outcome: [String: Double] = [
            "w1": 58, "w2": 62, "w3": 60, "w4": 59, "w5": 61,   // mean 60
            "o1": 78, "o2": 82, "o3": 80, "o4": 79, "o5": 81,   // mean 80
        ]
        let e = BehaviorInsights.effect(behaviorDays: ["w1", "w2", "w3", "w4", "w5"],
                                        controlDays: Set(outcome.keys).subtracting(["w1", "w2", "w3", "w4", "w5"]),
                                        outcomeByDay: outcome,
                                        behavior: "Alcohol", outcome: "Recovery")!
        let s = BehaviorInsights.sentence(e)
        XCTAssertEqual(s, "On days you logged ‘Alcohol’, Recovery was 25% lower (avg 60 vs 80, n=5 vs 5).")
    }

    func testSentenceHigherWithPercent() {
        let outcome: [String: Double] = [
            "w1": 79, "w2": 81, "w3": 80,    // mean 80
            "o1": 49, "o2": 51, "o3": 50,    // mean 50
        ]
        let e = BehaviorInsights.effect(behaviorDays: ["w1", "w2", "w3"],
                                        controlDays: Set(outcome.keys).subtracting(["w1", "w2", "w3"]),
                                        outcomeByDay: outcome,
                                        behavior: "Meditation", outcome: "Recovery")!
        let s = BehaviorInsights.sentence(e)
        // delta +30, pct +60% → "60% higher (avg 80 vs 50, n=3 vs 3)".
        XCTAssertEqual(s, "On days you logged ‘Meditation’, Recovery was 60% higher (avg 80 vs 50, n=3 vs 3).")
    }

    func testSentenceFallsBackToUnitsWhenPctUndefined() {
        // meanWithout 0 → pctChange nil → sentence uses absolute units.
        let outcome: [String: Double] = [
            "w1": 5, "w2": 5, "w3": 5,
            "o1": 0, "o2": 0, "o3": 0,
        ]
        let e = BehaviorInsights.effect(behaviorDays: ["w1", "w2", "w3"],
                                        controlDays: Set(outcome.keys).subtracting(["w1", "w2", "w3"]),
                                        outcomeByDay: outcome,
                                        behavior: "X", outcome: "HRV")!
        XCTAssertNil(e.pctChange)
        let s = BehaviorInsights.sentence(e)
        XCTAssertEqual(s, "On days you logged ‘X’, HRV was 5.0 higher (avg 5 vs 0, n=3 vs 3).")
    }
    // MARK: - Unlogged days are not answers (the Reddit report)

    /// "If I didn't track something for 100 days, NOOP takes that as a NO for 100 days, whereas it simply
    /// was not logged at all." Reported by a user on Reddit, and it was exactly what the split did.
    ///
    /// Twin of Kotlin `EffectRankerTest.daysWithNoJournalRowAreNotControls`.
    func testDaysWithNoJournalRowAreNotControls() {
        var outcome: [String: Double] = [:]
        var yes: Set<String> = []
        var no: Set<String> = []
        for d in 1...6 { let k = "y\(d)"; yes.insert(k); outcome[k] = Double(58 + d) }
        for d in 1...6 { let k = "n\(d)"; no.insert(k); outcome[k] = Double(68 + d) }
        // Never opened the journal on these, and their values sit far from BOTH answered groups.
        for d in 1...40 { outcome["u\(d)"] = Double(20 + (d % 3)) }

        let e = BehaviorInsights.effect(behaviorDays: yes, controlDays: no,
                                        outcomeByDay: outcome,
                                        behavior: "Alcohol", outcome: "Recovery")!
        // Controls are the six NO days only. Were the 40 unlogged days leaking in, nWithout would be 46
        // and meanWithout would be dragged towards 20.
        XCTAssertEqual(e.nWith, 6)
        XCTAssertEqual(e.nWithout, 6)
        XCTAssertGreaterThan(e.meanWithout, 60.0)
    }

    /// A behaviour the user only ever ticks Yes has no control group, so there is no comparison to make
    /// and the honest answer is none. Twin of Kotlin `aBehaviourNeverLoggedNoYieldsNothing`.
    func testBehaviourNeverLoggedNoYieldsNothing() {
        var outcome: [String: Double] = [:]
        var yes: Set<String> = []
        for d in 1...10 { let k = "y\(d)"; yes.insert(k); outcome[k] = Double(50 + d) }
        for d in 1...10 { outcome["u\(d)"] = Double(80 + d) }

        XCTAssertNil(BehaviorInsights.effect(behaviorDays: yes, controlDays: [],
                                             outcomeByDay: outcome,
                                             behavior: "Alcohol", outcome: "Recovery"))
    }

    /// rank() fails CLOSED on a caller that forgets the controls: no insight, rather than a wrong one
    /// measured against every day the user never opened the journal. Twin of Kotlin
    /// `rankWithoutControlsProducesNothingRatherThanGuessing`.
    func testRankWithoutControlsProducesNothingRatherThanGuessing() {
        var outcome: [String: Double] = [:]
        var yes: Set<String> = []
        for d in 1...10 { let k = "y\(d)"; yes.insert(k); outcome[k] = Double(50 + d) }
        for d in 1...20 { outcome["u\(d)"] = Double(75 + (d % 4)) }

        XCTAssertTrue(BehaviorInsights.rank(behaviors: ["Alcohol": yes], controls: [:],
                                            outcomeByDay: outcome, outcome: "Recovery").isEmpty)
    }

}
