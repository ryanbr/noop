import Foundation
import WhoopStore

// CoachSuggestions.swift — contextual coaching prompt chips derived from the user's own bands.
//
// Pure + deterministic so it is unit-testable without a strap, network, or app target, and so the
// output can be byte-identical to the Android twin `com.noop.analytics.CoachSuggestions` (the
// cross-platform parity contract: the same inputs produce the same chip strings on both platforms).
// Reads only DailyMetric fields that already live on-device; no new egress, no telemetry.

/// Contextual suggestion chips for the Coach composer, derived from today's bands.
public enum CoachSuggestions {

    /// The stable generic set used when there is no usable data for today. Byte-identical to the
    /// Android `FALLBACK` list.
    public static let fallback: [String] = [
        "How's my recovery trending this week?",
        "What should today's training look like?",
        "Analyse my sleep",
        "Why am I run down?",
    ]

    /// A stable generic prompt always appended as the last chip so there is a consistent entry point
    /// even when the contextual chips already cover the user's situation.
    private static let stableGeneric = "Analyse my sleep"

    /// Charge band cutoffs (mirrors the autoregulation bands in `AICoachEngine.defaultSystemPrompt`).
    private static let chargeRedCutoff: Double = 34
    private static let chargeGreenCutoff: Double = 67
    /// HRV "trending down" threshold: today's HRV below 85% of the trailing-30-day baseline (excluding
    /// today) flags a downward nudge. Matches the Android twin.
    private static let hrvDownRatio: Double = 0.85
    /// Sleep "poor night" cutoff: under 6h (360 min).
    private static let poorSleepMin: Double = 360
    /// "Already loaded" strain cutoff: a day strain at/above 14 reads as a high-load day.
    private static let highStrain: Double = 14
    /// Max chips surfaced.
    private static let maxChips: Int = 4

    /// Build 2–4 contextual prompt chips from today's bands, falling back to `fallback` when there is
    /// no usable data. `recent` is oldest→newest and is used for the trailing-30-day HRV baseline.
    ///
    /// - Parameters:
    ///   - today: today's (or the newest scored) `DailyMetric`; nil when no data is available.
    ///   - recent: recent days oldest→newest, for the HRV baseline. May be empty or may include today.
    /// - Returns: 2–4 chip strings (contextual) or the 4-string `fallback`.
    public static func suggestions(for today: DailyMetric?, recent: [DailyMetric]) -> [String] {
        guard let today else { return fallback }
        let charge = today.recovery
        let hrv = today.avgHrv
        let sleep = today.totalSleepMin
        let strain = today.strain
        // No usable signal at all → generic fallback.
        guard charge != nil || hrv != nil || sleep != nil || strain != nil else { return fallback }

        var chips: [String] = []

        // 1. Charge band → one readiness prescription chip.
        if let c = charge {
            if c < chargeRedCutoff {
                chips.append("Active recovery only today — what should I do?")
            } else if c < chargeGreenCutoff {
                chips.append("Quality over volume today — plan my session")
            } else {
                chips.append("Green light — how hard can I push today?")
            }
        }

        // 2. HRV trending down vs trailing-30-day baseline (excluding today).
        if let h = hrv {
            let baseline = hrvBaseline(recent, excluding: today.day)
            if let avg = baseline, avg > 0, h < hrvDownRatio * avg {
                chips.append("Why is my HRV trending down?")
            }
        }

        // 3. Poor sleep (< 6h).
        if let s = sleep, s < poorSleepMin {
            chips.append("I slept poorly — how do I recover today?")
        }

        // 4. Already a high-strain day.
        if let st = strain, st >= highStrain {
            chips.append("Have I done enough today, or push more?")
        }

        // Signals present but none of the band conditions fired → generic fallback (avoids a lone
        // stable chip when there's nothing contextual to say).
        guard !chips.isEmpty else { return fallback }
        // Cap the CONTEXTUAL chips at maxChips−1 so the stable generic always survives as the last
        // chip (a consistent entry point), then append it. Total never exceeds maxChips.
        return Array(chips.prefix(maxChips - 1)) + [stableGeneric]
    }

    /// Mean of `avgHrv` over the trailing 30 days of `recent`, excluding the day `excludingDay`.
    /// Returns nil when no qualifying night has an HRV value. Pure; byte-twin of the Android helper.
    private static func hrvBaseline(_ recent: [DailyMetric], excluding day: String) -> Double? {
        let values = recent.suffix(30).filter { $0.day != day }.compactMap { $0.avgHrv }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
