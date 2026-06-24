import Foundation

/// Estimate a strap's remaining runtime from its battery state-of-charge (SoC) history — the "~X days left"
/// the WHOOP app and WHOOP's API never give you (#713). NOOP already banks a SoC time-series from the strap
/// over BLE (the `battery` table), so NO manual logging is needed: we fit the recent DISCHARGE slope and
/// divide the current charge by it, falling back to the device's typical full-charge life when the discharge
/// data is too short to trust. The measured slope already reflects the user's real usage (HR-broadcast,
/// strain, …), so no hand-tuned multipliers are needed — the curve IS the personalisation.
///
/// APPROXIMATE: battery drain is non-linear (faster near full/empty) and usage-dependent, and the strap
/// reports SoC sparsely — this is an honest estimate, not a guarantee. Pure value type; the Kotlin twin is
/// BatteryEstimator.kt (kept byte-for-byte equivalent).
public enum BatteryEstimator {

    // MARK: - Tunables

    /// Typical full-charge life (hours) per generation — the cold-start fallback before enough of the user's
    /// OWN discharge is seen. WHOOP 4.0 ≈ 4.5 days, 5.0/MG ≈ 12 days (issue #713's figures). The caller maps
    /// its connected `DeviceFamily` to one of these.
    public static let ratedLifeHoursWhoop4: Double = 108
    public static let ratedLifeHoursWhoop5: Double = 288

    /// A discharge run must span at least this long AND drop at least this much before its measured slope is
    /// trusted over the rated fallback — short/noisy spans give wild rates.
    public static let minSpanHours: Double = 2.0
    public static let minDropPct: Double = 2.0
    /// A SoC rise beyond this (%) between consecutive readings marks a CHARGE — the discharge run restarts
    /// after it, so we never fit a rate across a charge.
    public static let chargeStepPct: Double = 1.0

    // MARK: - Output

    /// Whether the drain rate came from the user's own discharge (`measured`) or the rated fallback (`rated`).
    public enum Source: String, Equatable, Sendable { case measured, rated }

    public struct Estimate: Equatable, Sendable {
        /// Estimated hours of runtime left at the latest reading.
        public let remainingHours: Double
        public let source: Source
        /// The latest SoC the estimate is anchored to (%).
        public let currentSoc: Double
        public init(remainingHours: Double, source: Source, currentSoc: Double) {
            self.remainingHours = remainingHours; self.source = source; self.currentSoc = currentSoc
        }
    }

    // MARK: - Estimate

    /// Estimate remaining runtime. `readings` = `(unix-seconds, SoC%)` in any order (the caller drops nil-SoC
    /// rows and maps the `battery` series); `ratedLifeHours` = the strap's typical life (the `ratedLifeHours…`
    /// constants). Returns nil only when there isn't a single reading.
    public static func estimate(readings: [(ts: Int, soc: Double)], ratedLifeHours: Double) -> Estimate? {
        let r = readings.sorted { $0.ts < $1.ts }
        guard let last = r.last else { return nil }
        let current = last.soc

        // The trailing discharge run: everything after the most recent CHARGE step (SoC rising > chargeStepPct).
        var startIdx = 0
        if r.count >= 2 {
            for i in stride(from: r.count - 1, through: 1, by: -1) where r[i].soc > r[i - 1].soc + chargeStepPct {
                startIdx = i; break
            }
        }
        let seg = Array(r[startIdx...])

        let measuredRate: Double? = {
            guard let first = seg.first, let lastSeg = seg.last, seg.count >= 2 else { return nil }
            let spanH = Double(lastSeg.ts - first.ts) / 3600.0
            let drop = first.soc - lastSeg.soc
            guard spanH >= minSpanHours, drop >= minDropPct else { return nil }
            let rate = drop / spanH                  // %/h over the run
            return rate > 0 ? rate : nil
        }()

        let rate = measuredRate ?? (100.0 / max(ratedLifeHours, 1))
        let remaining = max(0, current) / rate
        let clamped = min(remaining, ratedLifeHours * 1.5)   // a fresh full charge can't exceed ~1.5× rated
        return Estimate(remainingHours: clamped,
                        source: measuredRate != nil ? .measured : .rated,
                        currentSoc: current)
    }

    /// The issue's display rule: hours under 48 h ("~14 h"), days above ("~4.8 days"). Unit-only — the caller
    /// adds the "left"/"remaining" copy. Locale-free for test stability; the UI localises the number.
    public static func label(hours: Double) -> String {
        if hours < 48 { return "~\(Int(hours.rounded())) h" }
        return "~\(String(format: "%.1f", hours / 24)) days"
    }
}
