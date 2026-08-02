import Foundation

// SleepDebt.swift — a rolling sleep-debt ledger over the last N nights.
//
// Pure, deterministic, DB-free. Given a chronological series of per-night total
// sleep (minutes) and a personal sleep need (hours), it accumulates a running
// balance of (actual − need) per night across a capped trailing window (14 nights
// by default) and reports the net balance plus the per-night deltas that make it
// up.
//
// HONEST by construction:
//   - It is a plain debt accumulator — sum of nightly (slept − need) — NOT a
//     physiological model. A surplus night (slept > need) genuinely offsets a
//     deficit one, the same way a checking balance nets credits and debits.
//   - The window is capped (default 14) so "debt" never compounds indefinitely
//     across months of history — only the recent fortnight is in scope.
//   - Nights with no usable sleep total are SKIPPED entirely (no zero-fill), so a
//     gap in wear never reads as a full night of debt.
//   - The need value is supplied by the caller (AnalyticsEngine.Rest.defaultNeedHours
//     = 8.0 by default; the caller passes any personal override). Computation here
//     stays a pure function of (series, need, window).
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
    /// Net running balance (minutes) across the window: Σ(slept − need). Negative =
    /// net DEBT (under-slept overall), positive = net SURPLUS, 0 = on target.
    public let balanceMin: Double
    /// Per-night contributions, oldest → newest, one per counted night (skipped
    /// nights are absent). The `deltaMin` values are the per-night bar/spark.
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
    /// short enough that one rough patch doesn't read as months of compounding debt.
    public static let defaultWindowNights: Int = 14

    /// "On target" deadband (minutes): a |balance| under this reads as balanced rather
    /// than as a debt/surplus, so a few stray minutes don't flip the headline.
    public static let onTargetBandMin: Double = 30.0

    /// Sleep credited toward debt for one day. `mainSleepMin` remains the canonical
    /// main-night total used by Rest and the sleep headline; separately-recorded naps
    /// add repayment credit without changing that canonical figure. A day with no
    /// usable main sleep stays missing, and a malformed negative nap total is ignored.
    ///
    /// This is deliberately arithmetic rather than a physiological model: callers
    /// classify the day's main-night group and pass only asleep minutes from blocks
    /// outside that group. Mirrored value-for-value in Kotlin `SleepDebt`.
    public static func creditedSleepMin(mainSleepMin: Double?, napSleepMin: Double = 0) -> Double? {
        guard let mainSleepMin, mainSleepMin > 0 else { return nil }
        return mainSleepMin + max(napSleepMin, 0)
    }

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
    /// The balance is Σ over the window of (sleptMin − needMin): a surplus night
    /// offsets a deficit one. Returns an empty ledger (balance 0, no nights) when no
    /// night has usable data.
    public static func ledger(series: [(day: String, totalSleepMin: Double?)],
                              needHours: Double = AnalyticsEngine.Rest.defaultNeedHours,
                              window: Int = defaultWindowNights) -> SleepDebtLedger {
        let needMin = max(needHours, 0.0) * 60.0
        let cap = max(window, 1)

        // Keep only nights with usable sleep, preserving chronological order, then take
        // the most-recent `cap` of them.
        let usable = series.filter { ($0.totalSleepMin ?? 0) > 0 }
        let windowed = usable.suffix(cap)

        var nights: [SleepDebtNight] = []
        nights.reserveCapacity(windowed.count)
        var balance = 0.0
        for row in windowed {
            let slept = row.totalSleepMin ?? 0
            let delta = slept - needMin
            balance += delta
            nights.append(SleepDebtNight(day: row.day, sleptMin: slept, deltaMin: delta))
        }
        return SleepDebtLedger(balanceMin: round1(balance), nights: nights, needMin: needMin)
    }

    /// Round to 1 decimal place (the ledger is reported in whole/near-whole minutes;
    /// 1 dp keeps Σ stable without trailing float noise). Mirrors the Kotlin rounding.
    static func round1(_ v: Double) -> Double { (v * 10.0).rounded() / 10.0 }
}
