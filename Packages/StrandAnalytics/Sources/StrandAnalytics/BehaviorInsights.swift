import Foundation

// BehaviorInsights.swift — does a logged behavior move an outcome?
//
// Pure, deterministic, DB-free. The headline data-interrogation feature: split the
// days where a behavior was logged (e.g. "Alcohol", "Late meal", "Meditation")
// from the days it was not, then compare the outcome metric (e.g. Recovery, HRV,
// sleep performance) between the two groups.
//
// For each behavior/outcome we report:
//   - meanWith / meanWithout : group means of the outcome.
//   - delta = meanWith − meanWithout, and pctChange relative to meanWithout.
//   - cohensD : standardised effect size using the POOLED standard deviation
//       sp = sqrt( ((n1−1)·s1² + (n2−1)·s2²) / (n1+n2−2) ),  d = (meanWith − meanWithout)/sp.
//   - pApprox : a two-sided p-value from Welch's t-test (unequal variances),
//       t  = (m1 − m2) / sqrt(s1²/n1 + s2²/n2),
//       df = (s1²/n1 + s2²/n2)² / ( (s1²/n1)²/(n1−1) + (s2²/n2)²/(n2−1) )  [Welch–Satterthwaite],
//     converted to a tail probability with a normal approximation (deterministic,
//     no special-function tables; slightly understates p for small samples).
//   - significant : pApprox < 0.05 AND min(nWith, nWithout) ≥ 5 (guards against
//     spurious "significance" from a handful of days).
//
// Effect direction is carried by the SIGN of delta / cohensD: a behavior that
// lowers the outcome yields negative values. `rank` orders behaviors by |cohensD|
// descending with significant effects first; `sentence` renders one in plain
// English for the UI.

/// The measured effect of one behavior on one outcome metric.
public struct BehaviorEffect: Equatable, Sendable {
    /// The behavior label (e.g. "Alcohol").
    public let behavior: String
    /// The outcome metric label (e.g. "Recovery").
    public let outcome: String
    /// Mean outcome on days the behavior WAS logged.
    public let meanWith: Double
    /// Mean outcome on days the behavior was NOT logged.
    public let meanWithout: Double
    /// meanWith − meanWithout (signed).
    public let delta: Double
    /// Percent change of meanWith relative to meanWithout, or nil when
    /// meanWithout is 0 (ratio undefined).
    public let pctChange: Double?
    /// Number of behavior-present days with an outcome value.
    public let nWith: Int
    /// Number of behavior-absent days with an outcome value.
    public let nWithout: Int
    /// Cohen's d using the pooled SD (signed; sign matches delta).
    public let cohensD: Double
    /// Two-sided p-value (Welch t-test, normal approximation).
    public let pApprox: Double
    /// pApprox < 0.05 AND min(nWith, nWithout) ≥ 5.
    public let significant: Bool

    public init(behavior: String, outcome: String, meanWith: Double, meanWithout: Double,
                delta: Double, pctChange: Double?, nWith: Int, nWithout: Int,
                cohensD: Double, pApprox: Double, significant: Bool) {
        self.behavior = behavior
        self.outcome = outcome
        self.meanWith = meanWith
        self.meanWithout = meanWithout
        self.delta = delta
        self.pctChange = pctChange
        self.nWith = nWith
        self.nWithout = nWithout
        self.cohensD = cohensD
        self.pApprox = pApprox
        self.significant = significant
    }
}

public enum BehaviorInsights {

    /// Minimum group size (each side) for an effect to be flagged significant.
    public static let minGroupForSignificance: Int = 5
    /// Significance threshold on the approximate p-value.
    public static let alpha: Double = 0.05

    // MARK: - Single behavior effect

    /// Compute the effect of `behavior` on `outcome`. "With" is day ∈ `behaviorDays`; "without" is
    /// day ∈ `controlDays`. Days in NEITHER are dropped, and that is the point of the second set.
    ///
    /// The split used to be `if behaviorDays.contains(day) { with } else { without }`, which made every
    /// day carrying an outcome a control — so a behaviour logged Yes on 20 days and never logged at all
    /// on the other 100 was measured against those 100 as though the user had answered No. Reported by a
    /// user on Reddit, in those terms: "if I didn't track something for 100 days, NOOP takes that as a
    /// NO for 100 days, whereas it simply was not logged at all."
    ///
    /// The journal already distinguishes the three states — a No writes a row with `answeredYes = false`,
    /// and only Clear deletes the row — so nothing but this split was conflating them.
    ///
    /// Expect FEWER findings, not better-looking ones. Unlogged days inflated nWithout, which shrinks the
    /// Welch p and helps clear the min(nWith, nWithout) gate; dropping them removes confidence that was
    /// never earned. A behaviour with no No days now yields nothing, which is the honest answer: with no
    /// controls there is no comparison to make.
    ///
    /// Returns nil unless BOTH groups are non-empty AND the total is large enough
    /// to form a variance estimate (at least 1 value per side and ≥ 3 total).
    public static func effect(behaviorDays: Set<String>,
                              controlDays: Set<String>,
                              outcomeByDay: [String: Double],
                              behavior: String,
                              outcome: String) -> BehaviorEffect? {
        var withVals: [Double] = []
        var withoutVals: [Double] = []
        for (day, value) in outcomeByDay {
            if behaviorDays.contains(day) { withVals.append(value) }
            else if controlDays.contains(day) { withoutVals.append(value) }
            // Neither: the behaviour was not logged that day. Not a control — no information.
            // A day in BOTH would count as "with"; callers merge imported ∪ native before building
            // these, so one question cannot hold two answers for one day.
        }

        let n1 = withVals.count
        let n2 = withoutVals.count
        // Need both groups present, and enough total points for a variance estimate.
        guard n1 >= 1, n2 >= 1, n1 + n2 >= 3 else { return nil }

        let m1 = withVals.reduce(0, +) / Double(n1)
        let m2 = withoutVals.reduce(0, +) / Double(n2)
        let delta = m1 - m2

        let pct: Double? = m2 != 0 ? (delta / abs(m2) * 100.0) : nil

        let v1 = sampleVariance(withVals, mean: m1)   // ddof=1; 0 when n==1
        let v2 = sampleVariance(withoutVals, mean: m2)

        let d = cohensD(m1: m1, m2: m2, n1: n1, v1: v1, n2: n2, v2: v2)
        let p = welchP(m1: m1, v1: v1, n1: n1, m2: m2, v2: v2, n2: n2)

        let sig = p < alpha && Swift.min(n1, n2) >= minGroupForSignificance

        return BehaviorEffect(behavior: behavior, outcome: outcome,
                              meanWith: m1, meanWithout: m2, delta: delta,
                              pctChange: pct, nWith: n1, nWithout: n2,
                              cohensD: d, pApprox: p, significant: sig)
    }

    // MARK: - Ranking

    /// Compute effects for every behavior in `behaviors` against one outcome and
    /// return them sorted by |cohensD| descending, with significant effects first.
    /// Behaviors that don't yield a computable effect are dropped.
    public static func rank(behaviors: [String: Set<String>],
                            controls: [String: Set<String>],
                            outcomeByDay: [String: Double],
                            outcome: String) -> [BehaviorEffect] {
        var effects: [BehaviorEffect] = []
        for (name, days) in behaviors {
            // A behaviour absent from `controls` has no controls and yields nothing — failing CLOSED, so
            // a caller that forgets loses the insight rather than getting a wrong one measured against
            // every day the user never opened the journal.
            if let e = effect(behaviorDays: days, controlDays: controls[name] ?? [],
                              outcomeByDay: outcomeByDay,
                              behavior: name, outcome: outcome) {
                effects.append(e)
            }
        }
        return effects.sorted { a, b in
            if a.significant != b.significant { return a.significant }  // significant first
            let la = abs(a.cohensD), lb = abs(b.cohensD)
            if la != lb { return la > lb }                              // bigger effect first
            return a.behavior < b.behavior                             // stable tiebreak
        }
    }

    // MARK: - Sentence

    /// Render an effect as a plain-English sentence for the UI, e.g.
    /// "On days you logged ‘Alcohol’, Recovery was 12% lower (avg 61 vs 69, n=140 vs 498)."
    /// Falls back to absolute units when pctChange is unavailable.
    public static func sentence(_ e: BehaviorEffect) -> String {
        let directionWord: String
        if e.delta > 0 { directionWord = "higher" }
        else if e.delta < 0 { directionWord = "lower" }
        else { directionWord = "unchanged" }

        let magnitude: String
        if e.delta == 0 {
            magnitude = "no different"
        } else if let pct = e.pctChange {
            magnitude = "\(roundedInt(abs(pct)))% \(directionWord)"
        } else {
            magnitude = "\(round1(abs(e.delta))) \(directionWord)"
        }

        let avgWith = roundedInt(e.meanWith)
        let avgWithout = roundedInt(e.meanWithout)

        return "On days you logged ‘\(e.behavior)’, \(e.outcome) was \(magnitude) "
            + "(avg \(avgWith) vs \(avgWithout), n=\(e.nWith) vs \(e.nWithout))."
    }

    // MARK: - Statistics helpers

    /// Sample variance (ddof = 1). 0 for fewer than 2 values.
    static func sampleVariance(_ values: [Double], mean: Double) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        var ss = 0.0
        for v in values { let d = v - mean; ss += d * d }
        return ss / Double(n - 1)
    }

    /// Cohen's d with the pooled SD. Falls back to 0 when the pooled SD is 0
    /// (no within-group spread) and the means are equal; when means differ but
    /// pooled SD is 0 the effect is undefined → reported as 0 (no spread to scale).
    static func cohensD(m1: Double, m2: Double, n1: Int, v1: Double,
                        n2: Int, v2: Double) -> Double {
        let df = n1 + n2 - 2
        guard df > 0 else { return 0 }
        let pooledVar = (Double(n1 - 1) * v1 + Double(n2 - 1) * v2) / Double(df)
        let sp = pooledVar.squareRoot()
        guard sp > 0 else { return 0 }
        return (m1 - m2) / sp
    }

    /// Two-sided Welch t-test p-value with a normal-approximation tail.
    /// Returns 1.0 (no evidence) when neither group has a usable standard error.
    static func welchP(m1: Double, v1: Double, n1: Int,
                       m2: Double, v2: Double, n2: Int) -> Double {
        let se2 = v1 / Double(n1) + v2 / Double(n2)
        guard se2 > 0 else {
            // No spread anywhere: identical means → p=1; differing means → p≈0.
            return m1 == m2 ? 1.0 : 0.0
        }
        let t = (m1 - m2) / se2.squareRoot()
        return 2.0 * (1.0 - CorrelationEngine.normalCDF(abs(t)))
    }

    // MARK: - Formatting helpers

    /// Round to nearest integer, returned as Int (for clean display).
    static func roundedInt(_ x: Double) -> Int { Int((x).rounded()) }

    /// Round to one decimal place.
    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
