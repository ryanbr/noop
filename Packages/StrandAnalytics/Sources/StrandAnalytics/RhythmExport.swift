import Foundation

// RhythmExport.swift — a plain-text (CSV) export of the DESCRIPTIVE rhythm-screening data
// for #1298: the §11 "share with my clinician" path. It formats the already-computed,
// on-device RhythmScreener output (per-window regularity statistics + the night roll-up)
// so a user can hand the actual timing data to a qualified professional.
//
// NON-CLINICAL, by construction and on purpose (read RhythmScreener + spec §11):
//   • It carries the exact non-diagnostic disclaimer as a header comment on the artifact
//     itself, not only on the screen it came from.
//   • It emits ONLY the neutral labels the engine already produces (steady / occasionalEctopy
//     / varied / unreadable). It names NO condition, emits NO verdict, NO probability, NO
//     "consider a clinician" call-to-action, and NO alarm. The judgement is the clinician's;
//     this hands them the data, not a guess.
//
// This is a user-facing EXPORT artifact, not a stored/analytics value, but it is nonetheless
// byte-identical across platforms: the numbers come from the same pure RhythmScreener, and `num`
// pre-rounds so the FORMATTING matches too (a user comparing an iPhone and an Android export of
// the same night sees the same file). Pure + deterministic; no clock, no I/O.
public enum RhythmExport {

    /// The disclaimer stamped on every export, verbatim from the Rhythm screen's own copy, so a
    /// shared file can never be read as a medical assessment on its own.
    public static let disclaimer: String =
        "NOOP Rhythm export — experimental wellness visualization, NOT a diagnosis. Not an ECG and "
        + "not a medical device; it cannot detect any heart condition. Beat-to-beat variation has many "
        + "ordinary, benign causes (breathing, movement, an imperfect optical reading, or the occasional "
        + "extra or skipped beat most healthy people have). Everything was computed on your device. "
        + "Share with a qualified professional if you wish; in an emergency, contact your local emergency service."

    static let header =
        "window,beats,sd1_ms,sd2_ms,sd1_sd2,norm_rmssd,turning_point_rate,ectopic_fraction,label,confidence"

    /// Build the CSV text for a night: a commented disclaimer + summary block, then one row per
    /// window (1-indexed in night order; the engine's WindowResult carries no wall-clock stamp).
    /// A nil statistic (an unreadable window) exports as an empty field, never a fabricated 0.
    public static func csv(summary: RhythmScreener.NightRhythmSummary,
                           windows: [RhythmScreener.WindowResult]) -> String {
        var lines: [String] = []
        for chunk in disclaimer.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("# \(chunk)")
        }
        lines.append("#")
        lines.append("# summary: readableWindows=\(summary.readableWindows) steady=\(summary.steadyWindows) "
            + "occasional=\(summary.occasionalWindows) varied=\(summary.variedWindows) "
            + "overall=\(summary.overall.rawValue) variationRecurred=\(summary.variationRecurred)")
        lines.append("#")
        lines.append(header)
        for (i, w) in windows.enumerated() {
            lines.append([
                String(i + 1),
                String(w.nBeats),
                num(w.sd1), num(w.sd2), num(w.sd1sd2), num(w.normRmssd),
                num(w.turningPointRate), num(w.ectopicFraction),
                w.label.rawValue, w.confidence.rawValue,
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Format an optional statistic to 3 decimals, or "" when the window was unreadable. Pre-rounds
    /// with half-away-from-zero (which Swift `.rounded()` and Kotlin `Math.round` share for the
    /// non-negative inputs here) BEFORE `%.3f`, so the export is byte-identical across platforms —
    /// `String(format:)` alone rounds half-to-even and would diverge from Java's half-up on an exact
    /// half (e.g. 0.0625 → 0.062 vs 0.063).
    private static func num(_ x: Double?) -> String {
        guard let x else { return "" }
        return String(format: "%.3f", (x * 1000).rounded() / 1000)
    }
}
