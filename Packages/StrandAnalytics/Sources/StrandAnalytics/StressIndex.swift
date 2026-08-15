import Foundation
import WhoopProtocol

// StressIndex.swift, Baevsky's Stress Index (SI), a histogram-based autonomic-balance metric.
//
// PURELY ADDITIVE display metric. Touches no Charge / Effort / Rest / sleep output.
//
// Baevsky's Stress Index (Baevsky & Berseneva; "regulatory systems" / cardiointervalography) summarises how
// "centralised" / sympathetically driven the heart rhythm is from the SHAPE of the R-R histogram:
//
//     SI = AMo / (2 * Mo * MxDMn)
//
//   • Mo   (mode, s)      : the most common R-R value, the histogram bin centre with the highest count.
//   • AMo  (amplitude     : the % of intervals falling in the modal bin, a TALL narrow peak (rigid,
//          of the mode, %)  sympathetically driven rhythm) gives a high AMo.
//   • MxDMn (variation    : range of R-R = max - min (s), a wide range (flexible, vagal) lowers SI.
//          range, s)
//
// A high SI means a tall, narrow, low-range histogram = a rigid rhythm = high sympathetic stress; a low SI
// means a broad, flat, wide-range histogram = a flexible rhythm = relaxed. The units follow the classic
// convention: R-R in SECONDS and Mo/MxDMn in seconds, AMo as a percentage (0–100), so SI is dimensionless.
//
// APPROXIMATE, non-clinical. Returned as a plain optional number for the UI lane to band/label later.

public enum StressIndex {

    /// Histogram bin width in SECONDS. Baevsky's method canonically bins R-R at 50 ms (0.05 s), the width
    /// used in cardiointervalography, so the mode and its amplitude are computed on the standard grid.
    public static let binWidthSec: Double = 0.05

    /// Minimum clean intervals before an SI is computed (the histogram needs enough beats to have a mode).
    public static let minBeats: Int = 20

    /// The intermediate histogram terms, exposed so the UI / a test can show the "why" behind an SI.
    public struct Components: Equatable, Sendable {
        /// Mode of the R-R histogram (s), centre of the most populated bin.
        public let moSec: Double
        /// Amplitude of the mode (%), share of intervals in the modal bin, 0–100.
        public let aMoPercent: Double
        /// Variation range MxDMn (s), max R-R minus min R-R over the cleaned series.
        public let mxDMnSec: Double
        /// SI = AMo / (2 * Mo * MxDMn).
        public let si: Double

        public init(moSec: Double, aMoPercent: Double, mxDMnSec: Double, si: Double) {
            self.moSec = moSec; self.aMoPercent = aMoPercent; self.mxDMnSec = mxDMnSec; self.si = si
        }
    }

    /// Baevsky Stress Index from R-R intervals (cleaned with the shared range + Malik ectopic pipeline).
    /// Returns nil when too few clean beats survive or the variation range is degenerate (all-equal beats,
    /// MxDMn == 0, would divide by zero, an honest nil, not Infinity).
    public static func stressIndex(rr: [RRInterval]) -> Double? {
        components(rr: rr)?.si
    }

    /// As `stressIndex(rr:)` but from a raw R-R series in milliseconds.
    public static func stressIndex(rawRR: [Double]) -> Double? {
        components(rawRR: rawRR)?.si
    }

    /// Full SI components from R-R intervals.
    public static func components(rr: [RRInterval]) -> Components? {
        components(rawRR: rr.map { Double($0.rrMs) })
    }

    /// Full SI components from a raw R-R series (ms). Pure, deterministic, no clock / IO.
    public static func components(rawRR: [Double]) -> Components? {
        let clean = HRVAnalyzer.cleanRR(rawRR)
        guard clean.count >= minBeats else { return nil }
        // #585 spot-honesty gate, matching HRVAnalyzer.analyze: a mostly-rejected capture (out-of-range or
        // ectopic beats) is too noisy to label as stress. clean.count >= minBeats > 0 => rawRR non-empty.
        guard 1.0 - Double(clean.count) / Double(rawRR.count) <= HRVAnalyzer.defaultSpotMaxRejectedFraction else { return nil }

        // Work in seconds (Baevsky's convention).
        let sec = clean.map { $0 / 1000.0 }
        let minV = sec.min()!
        let maxV = sec.max()!
        let mxDMn = maxV - minV
        guard mxDMn > 0 else { return nil }   // all-equal beats: no histogram spread, SI undefined.

        // Bin the series at binWidthSec; the modal bin is the one with the most intervals. Bin index is
        // floor((v - minV) / binWidth); the last value lands in the final bin by construction.
        let binCount = max(1, Int((mxDMn / binWidthSec).rounded(.down)) + 1)
        var counts = [Int](repeating: 0, count: binCount)
        for v in sec {
            var idx = Int(((v - minV) / binWidthSec).rounded(.down))
            if idx < 0 { idx = 0 }
            if idx >= binCount { idx = binCount - 1 }
            counts[idx] += 1
        }
        // Modal bin: highest count; ties resolve to the LOWEST bin index (deterministic across platforms).
        var modeIdx = 0
        var modeCount = counts[0]
        for i in 1..<binCount where counts[i] > modeCount {
            modeCount = counts[i]
            modeIdx = i
        }
        // Mo is the modal bin's CENTRE (s).
        let mo = minV + (Double(modeIdx) + 0.5) * binWidthSec
        let aMo = Double(modeCount) / Double(sec.count) * 100.0   // percentage in the modal bin

        guard mo > 0 else { return nil }
        let si = aMo / (2.0 * mo * mxDMn)
        return Components(moSec: mo, aMoPercent: aMo, mxDMnSec: mxDMn, si: si)
    }
}
