import Foundation

// SleepDebt.swift — a recency-weighted, capped, asymmetric sleep-debt ledger.
//
// Pure, deterministic, DB-free. Given a chronological series of per-night total
// sleep (minutes) and a personal sleep need (hours), it walks the recent nights
// oldest → newest and folds each night's (slept − need) into a running balance
// with three principled properties — recency weighting, a cap, and accrual/repay
// asymmetry — then reports the net balance plus the raw per-night deltas.
//
// The recurrence (oldest → newest over the counted, windowed nights, seeded at 0):
//
//     contribution = delta < 0 ? delta                          // a DEFICIT accrues in FULL
//                              : delta * surplusRepayFraction    // a SURPLUS repays only partly
//     balance      = recencyRetention * balance + contribution  // yesterday's balance DECAYS
//     balance      = clamp(balance, −cap, +cap)                 // cap = maxBalanceNights * need
//
//   where delta = sleptMin − needMin (positive = surplus, negative = deficit).
//
// Why each term (vs the old flat Σ(slept − need)):
//   - RECENCY WEIGHTING. `recencyRetention` (< 1) multiplies the carried balance each
//     night, so a night's imprint decays geometrically: its weight `k` counted nights
//     later is retentionᵏ. A fortnight-old deficit no longer sits at full weight the way
//     a flat sum held it. At the 0.90 default the half-life is ln0.5/ln0.90 ≈ 6.6 nights,
//     so across the 14-night window the oldest night carries ≈ 0.90¹³ ≈ 0.25 weight.
//   - CAP. Even decayed, a sustained deficit converges toward need/(1−retention) ≈ 10
//     nights' worth — still an absurd headline. `maxBalanceNights` clamps |balance| to a
//     few nights of need (a person-scaled ceiling), applied every step so the running
//     value never transiently blows past it either. The cap only binds under severe
//     chronic deprivation; realistic mild deficits sit well under it.
//   - ASYMMETRY. Two mechanisms, both grounded in sleep homeostasis: (1) a deficit accrues
//     in full but a surplus repays at `surplusRepayFraction` (< 1) — you cannot fully
//     "catch up" by oversleeping one night; (2) the retention decay itself repays debt over
//     time and prevents surplus from banking indefinitely. So an oversleep night moves the
//     balance strictly less than an equal-magnitude short night does.
//
// HONEST by construction:
//   - The per-night `deltaMin` stored on each `SleepDebtNight` stays the RAW signed
//     (slept − need), so the UI's diverging per-night bars remain a faithful nightly read.
//     Only the accumulated `balanceMin` applies the decay/asymmetry/cap — it is deliberately
//     NOT the plain Σ of the deltas any more (the model is the point).
//   - The trailing WINDOW (default 14) still caps how many counted nights are folded in;
//     decay and window together bound history.
//   - Nights with no usable sleep total are SKIPPED entirely (no zero-fill), so a gap in
//     wear never reads as a full night of debt, and decay is applied per COUNTED night (a
//     measurement gap does not silently "recover" the debt).
//   - The need value is supplied by the caller (AnalyticsEngine.Rest.defaultNeedHours = 8.0
//     by default; the caller passes any personal override — see SleepView, which now feeds
//     the population-anchored personalizedNeedHours rather than a self-referential mean).
//     Computation here stays a pure function of (series, need, window).
//
// The three tuning constants (`recencyRetention`, `surplusRepayFraction`, `maxBalanceNights`)
// are first-cut, defensible defaults that WANT empirical tuning on real wearer histories.
//
// Constant-explicit + dependency-free so the Kotlin mirror (android … SleepDebt.kt)
// is byte-identical.

/// One night's contribution to the ledger: its day key, minutes slept, and the
/// signed delta against need (positive = surplus, negative = deficit).
public struct SleepDebtNight: Equatable, Sendable {
    /// "yyyy-MM-dd" day key for the night (as carried on the DailyMetric).
    public let day: String
    /// Total sleep for the night (minutes).
    public let sleptMin: Double
    /// Signed delta vs need (minutes): sleptMin − needMin. Positive = surplus.
    public let deltaMin: Double

    public init(day: String, sleptMin: Double, deltaMin: Double) {
        self.day = day; self.sleptMin = sleptMin; self.deltaMin = deltaMin
    }
}

/// The rolling sleep-debt ledger over the capped trailing window.
public struct SleepDebtLedger: Equatable, Sendable {
    /// Net running balance (minutes): the recency-weighted, asymmetric, capped fold of the
    /// per-night deltas (see `SleepDebt.ledger`). Negative = net DEBT (under-slept overall),
    /// positive = net SURPLUS, 0 = on target. NOT the plain Σ of `nights[].deltaMin` — the
    /// decay/asymmetry/cap are applied to the accumulation, the raw deltas are kept only for
    /// the per-night bars.
    public let balanceMin: Double
    /// Per-night contributions, oldest → newest, one per counted night (skipped nights are
    /// absent). Each `deltaMin` is the RAW signed (slept − need) — the honest per-night
    /// bar/spark — before the balance's decay/asymmetry/cap are applied.
    public let nights: [SleepDebtNight]
    /// Personal sleep need (minutes) the ledger was computed against (for labelling).
    public let needMin: Double

    public init(balanceMin: Double, nights: [SleepDebtNight], needMin: Double) {
        self.balanceMin = balanceMin; self.nights = nights; self.needMin = needMin
    }

    /// Number of nights that contributed (nights with usable sleep data).
    public var nightCount: Int { nights.count }
    /// Convenience: true when the net balance is a debt (under need overall).
    public var isDebt: Bool { balanceMin < 0 }
    /// Magnitude of the balance in minutes, regardless of sign.
    public var magnitudeMin: Double { abs(balanceMin) }
}

public enum SleepDebt {

    /// Cap the ledger at the trailing two weeks — recent enough to be actionable,
    /// short enough that one rough patch doesn't read as months of compounding debt. With the
    /// recency decay layered on top, the window is a hard outer bound; the decay is what
    /// actually tapers a night's weight within it.
    public static let defaultWindowNights: Int = 14

    /// "On target" deadband (minutes): a |balance| under this reads as balanced rather
    /// than as a debt/surplus, so a few stray minutes don't flip the headline.
    public static let onTargetBandMin: Double = 30.0

    /// RECENCY WEIGHTING. Per-night retention of the carried balance: each night the running
    /// balance is multiplied by this before the night's contribution is added, so a night's
    /// weight decays geometrically (retentionᵏ, k counted nights later). 0.90 ⇒ 10 %/night
    /// decay, a ≈ 6.6-night half-life (ln0.5/ln0.90), and ≈ 0.25 weight on the oldest night of
    /// a 14-night window. Lower = shorter memory (only the last few nights matter); higher =
    /// longer memory (closer to the old flat sum). WANTS empirical tuning. Range (0, 1).
    public static let recencyRetention: Double = 0.90

    /// ASYMMETRY. A surplus (over-need) night repays debt at only this fraction of the weight a
    /// deficit night accrues at — you can't fully "bank" catch-up sleep by oversleeping once.
    /// 0.5 ⇒ an oversleep night moves the balance half as far as an equal short night. Combined
    /// with `recencyRetention` (which also quietly repays debt over time), this is the ledger's
    /// accrue-fast / repay-slow behaviour. WANTS empirical tuning. Range [0, 1].
    public static let surplusRepayFraction: Double = 0.5

    /// CAP. |balance| is clamped to this many nights of the personal need (cap = value × needMin),
    /// applied every step so the running total can't even transiently exceed it. Person-scaled so
    /// a longer-sleeping teen's ceiling is proportionally higher. 3 ⇒ "at most ~three full nights
    /// behind (or ahead)". Guards the absurd-number failure mode (a sustained deficit's decayed
    /// series still converges toward ~10 nights' worth without it). WANTS empirical tuning.
    public static let maxBalanceNights: Double = 3.0

    /// Build the ledger from a chronological `[(day, totalSleepMin?)]` series.
    ///
    /// - Parameters:
    ///   - series: per-night `(day, totalSleepMin)` rows in CHRONOLOGICAL order
    ///     (oldest → newest), exactly the order `repo.days` carries. A nil or
    ///     non-positive `totalSleepMin` marks a night with no usable data and is
    ///     SKIPPED (never zero-filled).
    ///   - needHours: personal sleep need (hours). The duration each night is measured
    ///     against. Defaults to `AnalyticsEngine.Rest.defaultNeedHours` (8 h); the
    ///     caller passes any per-user override.
    ///   - window: how many of the most-recent COUNTED nights to include. Defaults to
    ///     `defaultWindowNights` (14). Clamped to ≥ 1.
    ///
    /// The balance folds the windowed nights oldest → newest: each night's carried balance
    /// DECAYS by `recencyRetention`, a DEFICIT adds in full while a SURPLUS adds only
    /// `surplusRepayFraction` of itself, and |balance| is clamped to `maxBalanceNights` × need
    /// every step (see the file header for the full rationale). Each `SleepDebtNight.deltaMin`
    /// keeps the RAW (slept − need) for the per-night bars. Returns an empty ledger (balance 0,
    /// no nights) when no night has usable data.
    public static func ledger(series: [(day: String, totalSleepMin: Double?)],
                              needHours: Double = AnalyticsEngine.Rest.defaultNeedHours,
                              window: Int = defaultWindowNights) -> SleepDebtLedger {
        let needMin = max(needHours, 0.0) * 60.0
        let windowCap = max(window, 1)
        // Person-scaled magnitude ceiling for the running balance (a few nights of need).
        let balanceCap = maxBalanceNights * needMin

        // Keep only nights with usable sleep, preserving chronological order, then take
        // the most-recent `windowCap` of them.
        let usable = series.filter { ($0.totalSleepMin ?? 0) > 0 }
        let windowed = usable.suffix(windowCap)

        var nights: [SleepDebtNight] = []
        nights.reserveCapacity(windowed.count)
        var balance = 0.0
        for row in windowed {
            let slept = row.totalSleepMin ?? 0
            let delta = slept - needMin   // RAW signed per-night; kept for the bars
            // Asymmetry: a deficit (delta < 0) accrues in full; a surplus repays only partly.
            let contribution = delta < 0 ? delta : delta * surplusRepayFraction
            // Recency weighting: yesterday's balance decays before today's contribution lands.
            balance = recencyRetention * balance + contribution
            // Cap: clamp every step so the running total never even transiently exceeds it.
            balance = min(max(balance, -balanceCap), balanceCap)
            nights.append(SleepDebtNight(day: row.day, sleptMin: slept, deltaMin: delta))
        }
        return SleepDebtLedger(balanceMin: round1(balance), nights: nights, needMin: needMin)
    }

    /// Round to 1 decimal place (the ledger is reported in whole/near-whole minutes;
    /// 1 dp keeps Σ stable without trailing float noise). Mirrors the Kotlin rounding.
    static func round1(_ v: Double) -> Double { (v * 10.0).rounded() / 10.0 }
}
