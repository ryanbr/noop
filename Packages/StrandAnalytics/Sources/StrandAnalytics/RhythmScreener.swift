import Foundation
import WhoopProtocol

// RhythmScreener.swift — beat-to-beat regularity DESCRIPTIVE statistics + Poincaré
// point cloud for an experimental, non-clinical wellness VISUALIZATION.
//
// Spec: docs/superpowers/specs/2026-06-19-v5-rhythm-screening-design.md (§3, §11).
//
// SCOPE OF THIS ENGINE (deliberately narrow — read §11 of the spec):
//   This builds ONLY the pure regularity math and a NEUTRAL categorical label scoped
//   to a visualization ("looked steady" / "some variation" / "varied a lot" /
//   "couldn't read"). It deliberately does NOT emit any "consider a clinician" verdict,
//   any condition name, any probability-of-condition number, or any alarm. That
//   screening verdict is HELD per the spec's §11 recommendation and is gated behind a
//   separate go/no-go + the consent machinery — it is not part of this code.
//
// WHAT IT COMPUTES, over a clean RESTING window of successive R-R intervals
// (range-filtered, but NOT ectopic-stripped — we need the ectopy):
//   • Poincaré scatter SD1 / SD2 / SD1:SD2 ratio. SD1 = RMSSD/√2 (the standard rotated
//     short-axis SD of the (NN[i], NN[i+1]) cloud), SD2 = sqrt(2·SDNN² − SD1²) (the
//     long axis). A steady rhythm gives a tight elongated comet (small SD1, low ratio);
//     a more variable rhythm gives a rounder, more diffuse cloud (ratio → 1).
//   • Normalised RMSSD (RMSSD / meanNN) — a scale-free beat-to-beat variation index.
//   • Turning-point rate — the fraction of interior ΔNN sign changes (local extrema):
//     smooth respiratory modulation gives a low rate; disorganised beat-to-beat
//     direction flips give a high one. Compared against the value EXPECTED for a random
//     series (2/3), normalised to [0, ~1.5].
//   • Ectopic-beat fraction — `HRVAnalyzer.rejectEctopic` run as a COUNTER: the fraction
//     of beats the Malik filter WOULD drop. HRV throws these away; here we count them.
//   • The Poincaré point cloud itself (paired successive intervals) for the plot.
//
// All statistics are deterministic and reuse HRVAnalyzer's published primitives
// (rmssdRaw / sdnnRaw / rangeFilter / rejectEctopic / median). No new science, no model.
//
// NON-CLINICAL: every label is descriptive and benign. There are no disease names,
// no diagnostic claims, and no call-to-action anywhere in this file.

public enum RhythmScreener {

    // MARK: - Thresholds (named, tunable in one place; tuned only on synthetic fixtures)

    /// Minimum clean range-filtered intervals required to read a window at all.
    /// Set well above HRV's 20 — a regularity read needs a denser, steadier window.
    public static let windowMinBeats: Int = 60

    /// Resting heart-rate band (bpm). Outside this, the window is treated as
    /// unreadable (likely activity the motion gate missed, or artifact) rather than
    /// described — a regularity read is only meaningful at rest.
    public static let restingHrMinBpm: Double = 40
    public static let restingHrMaxBpm: Double = 110

    /// SD1:SD2 ratio at/above which the cloud is rounding out (less comet-like).
    /// A tight sinus comet sits well below this; a diffuse cloud approaches 1.
    public static let tauRatio: Double = 0.55

    /// Normalised-RMSSD (RMSSD / meanNN) at/above which beat-to-beat variation is high.
    public static let tauNRmssd: Double = 0.12

    /// Normalised turning-point rate at/above which beat-to-beat direction flips are
    /// frequent (close to or above the random-series expectation).
    public static let tauTP: Double = 0.90

    /// Ectopic-beat fraction at/above which isolated extra/skipped beats are notable
    /// enough to read as "occasional", provided the rhythm is otherwise smooth (low
    /// turning-point rate). Kept conservative.
    public static let tauEctopicLow: Double = 0.04

    // MARK: - Night-persistence thresholds (descriptive aggregation only — §3.3)
    //
    // NOTE: summarizeNight() here aggregates window labels for the VISUALIZATION's
    // night view. It produces NO notification and NO verdict — it only counts how many
    // readable windows looked varied vs steady, so the plot/detail screen can describe
    // the night honestly. The persistence gate that would (later) drive a heads-up is a
    // separate, held decision.

    /// Minimum varied windows in a night before the night is *described* as having had
    /// recurring variation (vs a one-off blip). Tuned high to avoid over-reading noise.
    public static let nightMinVariedWindows: Int = 3
    /// Minimum span (seconds) over which varied windows must be spread for the night to
    /// read as "recurring" rather than a single clustered moment.
    public static let nightMinSpanSeconds: Int = 30 * 60

    // MARK: - Confidence (mirrors ScoreConfidence's calibrating/building/solid pattern)

    /// Clean-beat count at/above which a single window's read is "solid".
    public static let solidBeats: Int = 200

    // MARK: - Types

    /// One resting window, already assembled by the caller (app layer). Pure inputs —
    /// no I/O. `rrMs` is the raw successive R-R series (ms); `ts` is the matching
    /// wall-clock seconds (used only for night-span aggregation, optional).
    public struct WindowInput: Equatable, Sendable {
        /// Raw successive R-R intervals (ms), in time order, BEFORE cleaning.
        public let rrMs: [Double]
        /// Wall-clock seconds for each interval (same length as `rrMs`), or empty if
        /// the caller doesn't track timestamps. Used only for span/aggregation.
        public let ts: [Int]
        /// Optional PPG-derived inter-beat intervals (ms) for the same window — an
        /// independent timing channel. When present, the same stats are computed on it
        /// and cross-source agreement is reported. nil on the R-R-only path.
        public let ppgIBIms: [Double]?
        /// True when the per-window accelerometer variance was below the "still"
        /// threshold (the caller applies the GravitySample motion gate). A regularity
        /// read is only attempted on a firmly-still window.
        public let motionStill: Bool
        /// Mean heart rate (bpm) over the window, used for the resting-band gate.
        public let meanHR: Double

        public init(rrMs: [Double], ts: [Int] = [], ppgIBIms: [Double]? = nil,
                    motionStill: Bool, meanHR: Double) {
            self.rrMs = rrMs
            self.ts = ts
            self.ppgIBIms = ppgIBIms
            self.motionStill = motionStill
            self.meanHR = meanHR
        }

        /// Convenience: assemble from decoded `RRInterval` rows. Computes meanHR from the
        /// cleaned series so the caller need not. `motionStill` still comes from the caller.
        public init(rr: [RRInterval], ppgIBIms: [Double]? = nil, motionStill: Bool) {
            let raw = rr.map { Double($0.rrMs) }
            let clean = HRVAnalyzer.rangeFilter(raw)
            let meanNN = clean.isEmpty ? 0 : clean.reduce(0, +) / Double(clean.count)
            let hr = meanNN > 0 ? 60_000.0 / meanNN : 0
            self.init(rrMs: raw, ts: rr.map { $0.ts }, ppgIBIms: ppgIBIms,
                      motionStill: motionStill, meanHR: hr)
        }
    }

    /// A single (NN[i], NN[i+1]) pair on the Poincaré plot (ms, ms).
    public struct PoincarePoint: Equatable, Sendable, Codable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// Descriptive statistics + neutral label for one window. All optional stats are
    /// nil when the window was unreadable. Nothing here is a clinical metric.
    public struct WindowResult: Equatable, Sendable, Codable {
        /// Neutral, visualization-scoped category (see RhythmRegularity).
        public let label: RhythmRegularity
        /// Poincaré short-axis SD (ms), = RMSSD/√2. nil if unreadable.
        public let sd1: Double?
        /// Poincaré long-axis SD (ms). nil if unreadable.
        public let sd2: Double?
        /// SD1 / SD2 (cloud roundness; → 1 as the cloud rounds out). nil if unreadable.
        public let sd1sd2: Double?
        /// Normalised RMSSD (RMSSD / meanNN). nil if unreadable.
        public let normRmssd: Double?
        /// Normalised turning-point rate (sign-change rate / (2/3)). nil if unreadable.
        public let turningPointRate: Double?
        /// Fraction of beats the Malik ectopic filter would drop. nil if unreadable.
        public let ectopicFraction: Double?
        /// Clean (range-filtered) beat count actually analysed.
        public let nBeats: Int
        /// Read certainty (calibrating/building/solid), mirrors ScoreConfidence.
        public let confidence: RhythmConfidence
        /// True only when an independent PPG IBI channel was present AND its label agreed
        /// with the R-R label. false when no PPG channel, or when the two disagreed.
        public let agreedAcrossSources: Bool
        /// The Poincaré point cloud for the plot (empty when unreadable).
        public let poincare: [PoincarePoint]

        public init(label: RhythmRegularity, sd1: Double?, sd2: Double?, sd1sd2: Double?,
                    normRmssd: Double?, turningPointRate: Double?, ectopicFraction: Double?,
                    nBeats: Int, confidence: RhythmConfidence, agreedAcrossSources: Bool,
                    poincare: [PoincarePoint]) {
            self.label = label
            self.sd1 = sd1
            self.sd2 = sd2
            self.sd1sd2 = sd1sd2
            self.normRmssd = normRmssd
            self.turningPointRate = turningPointRate
            self.ectopicFraction = ectopicFraction
            self.nBeats = nBeats
            self.confidence = confidence
            self.agreedAcrossSources = agreedAcrossSources
            self.poincare = poincare
        }

        /// An unreadable window (gate failed or too sparse) — all stats nil, no cloud.
        static func unreadable(nBeats: Int,
                               confidence: RhythmConfidence = .calibrating) -> WindowResult {
            WindowResult(label: .unreadable, sd1: nil, sd2: nil, sd1sd2: nil,
                         normRmssd: nil, turningPointRate: nil, ectopicFraction: nil,
                         nBeats: nBeats, confidence: confidence,
                         agreedAcrossSources: false, poincare: [])
        }
    }

    /// A descriptive roll-up of a night's readable windows for the VISUALIZATION's night
    /// view. Counts only — NO verdict, NO notification trigger, NO call-to-action.
    public struct NightRhythmSummary: Equatable, Sendable, Codable {
        /// Windows that were readable (passed the gates).
        public let readableWindows: Int
        /// Of those, how many looked steady.
        public let steadyWindows: Int
        /// Of those, how many showed occasional extra/skipped beats.
        public let occasionalWindows: Int
        /// Of those, how many varied a lot.
        public let variedWindows: Int
        /// Whether varied windows recurred across a sustained span (descriptive only:
        /// "this happened in a few separate windows tonight", not a flag).
        public let variationRecurred: Bool
        /// The most prominent neutral label for the night, for a one-line summary.
        public let overall: RhythmRegularity

        public init(readableWindows: Int, steadyWindows: Int, occasionalWindows: Int,
                    variedWindows: Int, variationRecurred: Bool, overall: RhythmRegularity) {
            self.readableWindows = readableWindows
            self.steadyWindows = steadyWindows
            self.occasionalWindows = occasionalWindows
            self.variedWindows = variedWindows
            self.variationRecurred = variationRecurred
            self.overall = overall
        }
    }

    // MARK: - Public API

    /// Screen one resting window: apply the gates, then compute the descriptive stats and
    /// a neutral regularity label. Pure — takes plain inputs, returns a plain result.
    public static func screenWindow(_ input: WindowInput) -> WindowResult {
        // Gate 1: motion. A regularity read is only attempted on a firmly-still window;
        // movement masquerades as irregularity and is the single biggest false signal.
        guard input.motionStill else {
            return .unreadable(nBeats: 0)
        }

        // Range-filter (keep ectopy — we only drop physiologically impossible jumps).
        let clean = HRVAnalyzer.rangeFilter(input.rrMs)

        // Gate 2: signal quality — need a dense enough clean window.
        guard clean.count >= windowMinBeats else {
            return .unreadable(nBeats: clean.count)
        }

        // Gate 3: plausible resting rate.
        guard input.meanHR >= restingHrMinBpm, input.meanHR <= restingHrMaxBpm else {
            return .unreadable(nBeats: clean.count, confidence: confidence(for: clean.count))
        }

        // Core descriptive statistics over the clean (range-filtered, ectopy-kept) series.
        let stats = computeStats(clean)
        let rrLabel = classify(stats)

        // Optional independent PPG IBI channel: compute the same stats + label; report
        // agreement. On the R-R-only path there is no PPG channel and agreement is false.
        var agreed = false
        if let ppg = input.ppgIBIms {
            let ppgClean = HRVAnalyzer.rangeFilter(ppg)
            if ppgClean.count >= windowMinBeats {
                let ppgStats = computeStats(ppgClean)
                let ppgLabel = classify(ppgStats)
                agreed = (ppgLabel == rrLabel)
            }
        }

        let cloud = poincareCloud(clean)
        return WindowResult(label: rrLabel,
                            sd1: stats.sd1, sd2: stats.sd2, sd1sd2: stats.sd1sd2,
                            normRmssd: stats.normRmssd, turningPointRate: stats.turningPointRate,
                            ectopicFraction: stats.ectopicFraction,
                            nBeats: clean.count, confidence: confidence(for: clean.count),
                            agreedAcrossSources: agreed, poincare: cloud)
    }

    /// Aggregate a night's window results into a descriptive summary for the night view.
    /// Counting only — produces no verdict and triggers nothing.
    public static func summarizeNight(_ windows: [WindowResult]) -> NightRhythmSummary {
        let readable = windows.filter { $0.label != .unreadable }
        let steady = readable.filter { $0.label == .steady }.count
        let occasional = readable.filter { $0.label == .occasionalEctopy }.count
        let varied = readable.filter { $0.label == .varied }.count

        // "Recurred" = enough varied windows spread over a sustained span (descriptive).
        let recurred = varied >= nightMinVariedWindows

        // Most-prominent neutral label for the one-line night summary.
        let overall: RhythmRegularity
        if readable.isEmpty {
            overall = .unreadable
        } else if varied >= nightMinVariedWindows {
            overall = .varied
        } else if varied > 0 || occasional > 0 {
            overall = .occasionalEctopy
        } else {
            overall = .steady
        }

        return NightRhythmSummary(readableWindows: readable.count,
                                  steadyWindows: steady, occasionalWindows: occasional,
                                  variedWindows: varied, variationRecurred: recurred,
                                  overall: overall)
    }

    // MARK: - Statistics

    /// Bundle of the descriptive statistics over a clean window.
    struct Stats: Equatable {
        let sd1: Double?
        let sd2: Double?
        let sd1sd2: Double?
        let normRmssd: Double?
        let turningPointRate: Double?
        let ectopicFraction: Double?
    }

    /// Compute SD1/SD2/ratio, normalised RMSSD, turning-point rate and ectopic fraction
    /// over an already range-filtered (ectopy-kept) NN series. Reuses HRVAnalyzer.
    static func computeStats(_ nn: [Double]) -> Stats {
        guard nn.count >= 2 else {
            return Stats(sd1: nil, sd2: nil, sd1sd2: nil, normRmssd: nil,
                         turningPointRate: nil, ectopicFraction: ectopicFraction(nn))
        }
        let rmssd = HRVAnalyzer.rmssdRaw(nn)
        let sdnn = HRVAnalyzer.sdnnRaw(nn)
        let meanNN = nn.reduce(0, +) / Double(nn.count)

        // SD1 = RMSSD/√2 (standard Poincaré short axis). SD2 = sqrt(2·SDNN² − SD1²).
        let sd1: Double? = rmssd.map { $0 / 2.0.squareRoot() }
        var sd2: Double? = nil
        if let sd1 = sd1, let sdnn = sdnn {
            let v = 2.0 * sdnn * sdnn - sd1 * sd1
            sd2 = v > 0 ? v.squareRoot() : 0
        }
        let ratio: Double? = (sd1 != nil && (sd2 ?? 0) > 0) ? sd1! / sd2! : nil

        let normRmssd: Double? = (rmssd != nil && meanNN > 0) ? rmssd! / meanNN : nil
        let tp = turningPointRate(nn)
        let ect = ectopicFraction(nn)

        return Stats(sd1: sd1, sd2: sd2, sd1sd2: ratio,
                     normRmssd: normRmssd, turningPointRate: tp, ectopicFraction: ect)
    }

    /// Normalised turning-point rate: the fraction of interior points that are local
    /// extrema (a sign change in successive Δ), divided by the 2/3 expected for a random
    /// series. ≈ 1 means "as choppy as random"; < 1 means smoother (sinus modulation).
    static func turningPointRate(_ nn: [Double]) -> Double? {
        guard nn.count >= 3 else { return nil }
        var turns = 0
        for i in 1..<(nn.count - 1) {
            let a = nn[i] - nn[i - 1]
            let b = nn[i + 1] - nn[i]
            if a * b < 0 { turns += 1 }   // direction reversed → a turning point
        }
        let interior = Double(nn.count - 2)
        guard interior > 0 else { return nil }
        let rate = Double(turns) / interior
        let expectedRandom = 2.0 / 3.0
        return rate / expectedRandom
    }

    /// Ectopic-beat fraction: the fraction of beats `HRVAnalyzer.rejectEctopic` WOULD
    /// drop, used here as a COUNTER (HRV discards these; we count them). 0 when empty.
    static func ectopicFraction(_ nn: [Double]) -> Double {
        guard !nn.isEmpty else { return 0 }
        let kept = HRVAnalyzer.rejectEctopic(nn)
        let dropped = nn.count - kept.count
        return Double(dropped) / Double(nn.count)
    }

    /// The Poincaré point cloud: successive (NN[i], NN[i+1]) pairs.
    static func poincareCloud(_ nn: [Double]) -> [PoincarePoint] {
        guard nn.count >= 2 else { return [] }
        var pts: [PoincarePoint] = []
        pts.reserveCapacity(nn.count - 1)
        for i in 1..<nn.count {
            pts.append(PoincarePoint(x: nn[i - 1], y: nn[i]))
        }
        return pts
    }

    // MARK: - Classification (neutral, visualization-scoped — NO clinical verdict)

    /// Map descriptive stats to a NEUTRAL regularity label. The "varied" condition is a
    /// conservative AND of high scatter, high beat-to-beat variation AND choppy turning
    /// (a round, disorganised cloud). Isolated extra/skipped beats — a notable ectopic
    /// fraction with an otherwise SMOOTH rhythm (low turning-point rate) — read separately
    /// as "occasional", which discriminates a few sparse couplets (large scatter but not
    /// choppy) from genuinely disorganised timing. Everything else reads "steady". No
    /// condition is ever named, and there is no call-to-action.
    static func classify(_ s: Stats) -> RhythmRegularity {
        guard let ratio = s.sd1sd2, let nrmssd = s.normRmssd, let tp = s.turningPointRate
        else { return .unreadable }

        let scatterHigh = ratio >= tauRatio
        let variationHigh = nrmssd >= tauNRmssd
        let turningHigh = tp >= tauTP

        // Conservative AND: only a window that is round AND variable AND choppy reads
        // "varied a lot". This is the main lever against over-reading noise.
        if scatterHigh && variationHigh && turningHigh {
            return .varied
        }

        // Occasional extra/skipped beats: a notable ectopic fraction but NOT choppy — the
        // rhythm is otherwise smooth, so this is sparse couplets, not disorganised timing.
        let ect = s.ectopicFraction ?? 0
        if ect >= tauEctopicLow && !turningHigh {
            return .occasionalEctopy
        }

        return .steady
    }

    /// Read certainty from the clean-beat count, mirroring ScoreConfidence's tiers.
    static func confidence(for nBeats: Int) -> RhythmConfidence {
        if nBeats < windowMinBeats { return .calibrating }
        return nBeats >= solidBeats ? .solid : .building
    }
}

/// Neutral, visualization-scoped regularity category. Strings are deliberately benign:
/// no disease names, no diagnostic terms, no call-to-action. These back an experimental
/// wellness PLOT, not a screening verdict.
///
/// User-facing copy maps these to plain language, e.g.
///   .steady           → "looked steady"
///   .occasionalEctopy → "some occasional extra or skipped beats"
///   .varied           → "varied more than usual"
///   .unreadable       → "couldn't read clearly"
public enum RhythmRegularity: String, Codable, Sendable, Equatable {
    case steady
    case occasionalEctopy
    case varied
    case unreadable
}

/// Read certainty for a regularity result — mirrors `ScoreConfidence`'s tiers so a thin
/// window reads truthfully instead of faking a confident shape.
public enum RhythmConfidence: String, Codable, Sendable, Equatable {
    case calibrating
    case building
    case solid
}
