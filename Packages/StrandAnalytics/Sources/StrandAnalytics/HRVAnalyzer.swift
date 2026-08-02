import Foundation
import WhoopProtocol

// HRVAnalyzer.swift — RMSSD + SDNN from RR intervals with cleaning.
//
// Ported from server/ingest/app/analysis/hrv.py. The Task Force (1996) RMSSD and
// SDNN definitions are reproduced exactly:
//
//   RMSSD = sqrt( mean( (NN[i+1] − NN[i])^2 ) )           (Task Force 1996)
//   SDNN  = sample standard deviation of NN (ddof = 1)     (Task Force 1996)
//
// Cleaning pipeline:
//   1. Range filter: drop intervals outside [RR_MIN_MS, RR_MAX_MS] = [300, 2000] ms.
//   2. Ectopic rejection: drop beats whose RR deviates > ~20% from a local median
//      (Malik-style filter).
//   3. Require >= MIN_BEATS (20) valid intervals before a trustworthy result.
//
// NOTE: the Python source runs neurokit2's Kubios / Lipponen–Tarvainen (2019)
// artifact classifier, which is unavailable on-device. We substitute the
// classical Malik 20% local-median rule (Malik et al. 1989), the most widely
// cited ectopic-rejection heuristic. This is a simpler, fully-deterministic
// approximation of the same intent — remove physiologically impossible
// beat-to-beat jumps before computing HRV — at the cost of not modelling the
// missed/extra-beat insertion that Kubios does.

public enum HRVAnalyzer {

    /// Minimum plausible RR interval (ms) — 300 ms ≈ 200 bpm.
    public static let rrMinMs: Double = 300
    /// Maximum plausible RR interval (ms) — 2000 ms ≈ 30 bpm.
    public static let rrMaxMs: Double = 2000
    /// Minimum valid intervals required for a trustworthy RMSSD/SDNN.
    public static let minBeats: Int = 20
    /// Malik-style ectopic threshold: a beat deviating more than this fraction
    /// from the local median is rejected. 0.20 == 20%.
    public static let ectopicThreshold: Double = 0.20
    /// Half-width (in beats) of the local-median window used for ectopic rejection.
    /// A window of 2*radius+1 beats (5 beats at radius 2) matches the common
    /// Malik moving-window implementations.
    public static let ectopicWindowRadius: Int = 2

    /// Default ceiling on the fraction of input beats the cleaning pipeline may reject before a SPOT
    /// reading is refused as too noisy (#585). Spot-only: passed by the on-demand callers, never by the
    /// nightly windowed path. 0.35 == refuse once more than 35% of beats were dropped as out-of-range or
    /// ectopic, even if `minBeats` clean intervals survive — a quiet honesty gate on a short, live capture.
    public static let defaultSpotMaxRejectedFraction: Double = 0.35

    /// Result of an HRV computation over a window.
    public struct HRVResult: Equatable, Sendable {
        /// RMSSD in milliseconds, or nil when too few valid beats.
        public let rmssd: Double?
        /// SDNN (sample SD, ddof=1) in milliseconds, or nil when too few valid beats.
        public let sdnn: Double?
        /// Mean NN interval (ms) over the cleaned beats, or nil.
        public let meanNN: Double?
        /// pNN50: % of successive |ΔNN| > 50 ms, or nil.
        public let pnn50: Double?
        /// Count of RR intervals supplied to the analysis (before cleaning).
        public let nInput: Int
        /// Count of clean NN intervals after range + ectopic filtering.
        public let nClean: Int

        public init(rmssd: Double?, sdnn: Double?, meanNN: Double?, pnn50: Double?,
                    nInput: Int, nClean: Int) {
            self.rmssd = rmssd
            self.sdnn = sdnn
            self.meanNN = meanNN
            self.pnn50 = pnn50
            self.nInput = nInput
            self.nClean = nClean
        }

        /// An empty/insufficient-data result that preserves the input count.
        static func empty(nInput: Int) -> HRVResult {
            HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil,
                      nInput: nInput, nClean: 0)
        }
    }

    // MARK: - Primitive Task Force statistics (no filtering)

    /// Task Force (1996) RMSSD over already-clean NN intervals (ms). Returns nil
    /// when fewer than 2 values (no successive differences). No filtering applied.
    public static func rmssdRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<nn.count {
            let d = nn[i] - nn[i - 1]
            sumSq += d * d
        }
        return (sumSq / Double(nn.count - 1)).squareRoot()
    }

    /// Sample standard deviation (ddof = 1) of NN intervals (ms). Returns nil for
    /// fewer than 2 values. Matches neurokit2 HRV_SDNN. No filtering applied.
    public static func sdnnRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        let mean = nn.reduce(0, +) / Double(nn.count)
        var ss = 0.0
        for v in nn { let d = v - mean; ss += d * d }
        return (ss / Double(nn.count - 1)).squareRoot()
    }

    // MARK: - Cleaning

    /// Range filter: keep only intervals in [rrMinMs, rrMaxMs], preserving order.
    public static func rangeFilter(_ rr: [Double]) -> [Double] {
        rr.filter { $0 >= rrMinMs && $0 <= rrMaxMs }
    }

    /// Malik-style ectopic rejection: drop any beat that deviates from its local
    /// median by more than `ectopicThreshold` (20%). The local median is taken
    /// over a centered window of `2*ectopicWindowRadius+1` beats (excluding the
    /// beat under test). Beats with too small a neighbourhood are kept.
    ///
    /// NOTE: this replaces neurokit2's Kubios classifier (see file header).
    public static func rejectEctopic(_ nn: [Double]) -> [Double] {
        guard nn.count > ectopicWindowRadius else { return nn }
        var kept: [Double] = []
        kept.reserveCapacity(nn.count)
        for i in 0..<nn.count {
            let lo = max(0, i - ectopicWindowRadius)
            let hi = min(nn.count - 1, i + ectopicWindowRadius)
            var neighbours: [Double] = []
            neighbours.reserveCapacity(hi - lo)
            for j in lo...hi where j != i { neighbours.append(nn[j]) }
            guard neighbours.count >= 2 else { kept.append(nn[i]); continue }
            let med = median(neighbours)
            if med <= 0 { kept.append(nn[i]); continue }
            let deviation = abs(nn[i] - med) / med
            if deviation <= ectopicThreshold {
                kept.append(nn[i])
            }
            // else: drop this beat as ectopic.
        }
        return kept
    }

    /// Full clean: range filter → ectopic rejection. Returns the clean NN series.
    public static func cleanRR(_ rr: [Double]) -> [Double] {
        rejectEctopic(rangeFilter(rr))
    }

    // MARK: - Gap-aware cleaning (successive-difference safety) — #204/#195

    /// A cleaned NN series that remembers where beats were dropped. `nn` is byte-identical to `cleanRR`
    /// over the same input. `contiguous` has the same length: `contiguous[i]` is true when `nn[i]` and
    /// `nn[i-1]` were adjacent beats in the ORIGINAL series (no beat removed between them by the range or
    /// ectopic filter) and false when a beat was dropped in between (a splice). Index 0 is always false.
    public struct CleanSeries: Equatable, Sendable {
        public let nn: [Double]
        public let contiguous: [Bool]
    }

    /// Clean the RR series (range filter then Malik ectopic rejection, exactly like `cleanRR`) while
    /// tracking which original beats were dropped, so a downstream successive-difference metric can skip
    /// the difference across a removed beat. `CleanSeries.nn` equals `cleanRR` value for value. Kotlin twin
    /// of `HrvAnalyzer.cleanRRGapAware`.
    public static func cleanRRGapAware(_ rr: [Double]) -> CleanSeries {
        // Pass 1: range filter, keeping each survivor's index in the ORIGINAL series.
        var rangedIdx: [Int] = []; rangedIdx.reserveCapacity(rr.count)
        var rangedVal: [Double] = []; rangedVal.reserveCapacity(rr.count)
        for i in 0..<rr.count {
            let v = rr[i]
            if v >= rrMinMs && v <= rrMaxMs { rangedIdx.append(i); rangedVal.append(v) }
        }
        // Pass 2: Malik ectopic rejection over the range-filtered values, mirroring `rejectEctopic`
        // (same windows, same median, same threshold) so the kept values match `cleanRR` exactly, while
        // carrying each survivor's original index forward.
        var keptOrig: [Int] = []; keptOrig.reserveCapacity(rangedVal.count)
        var keptVal: [Double] = []; keptVal.reserveCapacity(rangedVal.count)
        if rangedVal.count <= ectopicWindowRadius {
            // rejectEctopic returns the input unchanged for a series this short.
            for k in 0..<rangedVal.count { keptOrig.append(rangedIdx[k]); keptVal.append(rangedVal[k]) }
        } else {
            for i in 0..<rangedVal.count {
                let lo = max(0, i - ectopicWindowRadius)
                let hi = min(rangedVal.count - 1, i + ectopicWindowRadius)
                var neighbours: [Double] = []; neighbours.reserveCapacity(hi - lo)
                for j in lo...hi where j != i { neighbours.append(rangedVal[j]) }
                let keep: Bool
                if neighbours.count < 2 {
                    keep = true
                } else {
                    let med = median(neighbours)
                    keep = med <= 0 ? true : abs(rangedVal[i] - med) / med <= ectopicThreshold
                }
                if keep { keptOrig.append(rangedIdx[i]); keptVal.append(rangedVal[i]) }
            }
        }
        // A survivor is contiguous with its predecessor only when their ORIGINAL indices are adjacent.
        var contiguous: [Bool] = []; contiguous.reserveCapacity(keptVal.count)
        for i in 0..<keptVal.count { contiguous.append(i > 0 && keptOrig[i] == keptOrig[i - 1] + 1) }
        return CleanSeries(nn: keptVal, contiguous: contiguous)
    }

    /// Task Force RMSSD that counts a successive difference only when the two beats were adjacent in the
    /// source (`CleanSeries.contiguous`). A difference spanning a dropped beat is skipped, so removing an
    /// out-of-range/ectopic beat cannot splice its neighbours into a spurious delta. Identical to
    /// `rmssdRaw` when there are no gaps. nil when no valid successive difference exists. Kotlin twin.
    public static func rmssdGapAware(_ nn: [Double], _ contiguous: [Bool]) -> Double? {
        precondition(nn.count == contiguous.count, "nn and contiguous must be the same length")
        var sumSq = 0.0
        var count = 0
        var i = 1
        while i < nn.count {
            if contiguous[i] {
                let d = nn[i] - nn[i - 1]
                sumSq += d * d
                count += 1
            }
            i += 1
        }
        return count < 1 ? nil : (sumSq / Double(count)).squareRoot()
    }

    /// pNN50 that counts a successive pair only when the two beats were adjacent in the source, skipping
    /// any pair straddling a dropped beat. Identical to the plain pNN50 when there are no gaps. nil when
    /// no valid successive pair exists. Kotlin twin of `HrvAnalyzer.pnn50GapAware`.
    public static func pnn50GapAware(_ nn: [Double], _ contiguous: [Bool]) -> Double? {
        precondition(nn.count == contiguous.count, "nn and contiguous must be the same length")
        var nn50 = 0
        var pairs = 0
        var i = 1
        while i < nn.count {
            if contiguous[i] {
                if abs(nn[i] - nn[i - 1]) > 50.0 { nn50 += 1 }
                pairs += 1
            }
            i += 1
        }
        return pairs < 1 ? nil : Double(nn50) / Double(pairs) * 100.0
    }

    // MARK: - Windowed analysis

    /// Compute HRV (RMSSD/SDNN/meanNN/pNN50) over the RR intervals whose ts falls
    /// in [windowStart, windowEnd] (inclusive). Pass nil bounds to use all rows.
    ///
    /// Applies the range filter, Malik ectopic rejection, then requires
    /// `minBeats` clean intervals; otherwise returns an empty result.
    public static func analyze(_ rr: [RRInterval],
                               windowStart: Int? = nil,
                               windowEnd: Int? = nil) -> HRVResult {
        let inWindow = rr.filter { sample in
            if let s = windowStart, sample.ts < s { return false }
            if let e = windowEnd, sample.ts > e { return false }
            return true
        }
        let raw = inWindow.map { Double($0.rrMs) }
        return analyze(rawRR: raw)
    }

    /// Compute HRV from raw RR-interval values (ms), applying the full cleaning
    /// pipeline. Returns an empty result when fewer than `minBeats` survive.
    ///
    /// - Parameter maxRejectedFraction: SPOT-ONLY honesty gate (#585). When non-nil, the reading is ALSO
    ///   refused (empty result) if the fraction of input beats dropped by cleaning exceeds this value —
    ///   even when `minBeats` clean intervals survive — because a short live capture that threw away most
    ///   of its beats is too noisy to trust. nil (the default, and what the NIGHTLY windowed path passes)
    ///   skips the gate entirely, so the nightly RMSSD is byte-identical to before this parameter existed.
    public static func analyze(rawRR: [Double], maxRejectedFraction: Double? = nil) -> HRVResult {
        let nInput = rawRR.count
        let cleaned = cleanRRGapAware(rawRR)
        let clean = cleaned.nn
        guard clean.count >= minBeats else {
            return .empty(nInput: nInput)
        }
        // Spot-only: refuse when too large a fraction of beats was noise (out-of-range or ectopic). Only
        // applied when a ceiling is supplied; a guard against nInput == 0 is implicit (clean ≥ minBeats > 0).
        if let maxRejectedFraction, nInput > 0 {
            let rejectedFraction = 1.0 - Double(clean.count) / Double(nInput)
            if rejectedFraction > maxRejectedFraction {
                return .empty(nInput: nInput)
            }
        }
        // #204/#195: RMSSD and pNN50 are gap-aware — a successive difference across a dropped beat is
        // skipped so a removed out-of-range/ectopic beat can't splice its neighbours into a spurious delta.
        // SDNN and meanNN use every clean beat (no successive differences), so they are unchanged.
        let rmssd = rmssdGapAware(cleaned.nn, cleaned.contiguous)
        let sdnn = sdnnRaw(clean)
        let mean = clean.reduce(0, +) / Double(clean.count)
        let pnn50 = pnn50GapAware(cleaned.nn, cleaned.contiguous)

        return HRVResult(rmssd: rmssd, sdnn: sdnn, meanNN: mean, pnn50: pnn50,
                         nInput: nInput, nClean: clean.count)
    }

    // MARK: - Rolling / windowed rMSSD timeline (#803)

    /// One windowed rMSSD point: the rMSSD (ms) over the trailing `windowSec` of R-R intervals ending at
    /// `ts` (wall-clock unix seconds). This is an HONEST windowed rMSSD, NOT a single "HRV" number for the
    /// night - the .hrv timeline plots a point per emitted window so an autonomic-tone report (#803) shows
    /// rMSSD MOVING across the session instead of one opaque figure.
    public struct RollingRmssdPoint: Equatable, Sendable {
        /// Wall-clock unix seconds of the last R-R interval folded into this window (the window's right edge).
        public let ts: Int
        /// rMSSD (ms) over the cleaned R-R intervals inside the trailing window.
        public let rmssd: Double
        public init(ts: Int, rmssd: Double) { self.ts = ts; self.rmssd = rmssd }
    }

    /// Pure rolling/windowed rMSSD over an R-R series (#803). For each input interval, the window is the
    /// trailing `windowSec` seconds ending at that interval's `ts`; the window's R-R values are cleaned with
    /// the SAME range filter + Malik ectopic rejection the nightly path uses (`cleanRR`), and a point is
    /// emitted only when at least `minBeatsPerWindow` clean intervals survive (so a sparse / artifact-heavy
    /// window emits nothing rather than a noisy spike). The result is one `(ts, rMSSD)` per qualifying
    /// window, in input order.
    ///
    /// - Parameters:
    ///   - rr: the R-R intervals (each carries its own wall-clock `ts` and `rrMs`). Need not be pre-sorted;
    ///     sorted ascending by `ts` internally so the trailing window is well-defined.
    ///   - windowSec: the trailing window width in seconds (e.g. 120 for a 2-minute rMSSD).
    ///   - stepSec: emit at most one point per this many seconds of advance (a thinning stride so a 1 Hz
    ///     stream does not emit a point per beat). 0 (the default) emits a point at every interval.
    ///   - minBeatsPerWindow: minimum clean intervals a window needs to emit a point. Defaults to a small
    ///     floor (8) because a short window legitimately holds far fewer beats than the nightly `minBeats`.
    public static func rollingRmssd(rr: [RRInterval],
                                    windowSec: Int,
                                    stepSec: Int = 0,
                                    minBeatsPerWindow: Int = 8) -> [RollingRmssdPoint] {
        guard windowSec > 0, rr.count >= minBeatsPerWindow else { return [] }
        // Stable: preserves the store's #823 emission order for same-second beats, which RMSSD needs.
        let sorted = rr.sortedByTsStable()
        var out: [RollingRmssdPoint] = []
        var lastEmitTs: Int? = nil
        var left = 0   // index of the oldest interval still inside the trailing window
        for right in 0..<sorted.count {
            let edgeTs = sorted[right].ts
            // Advance the left edge so [left, right] spans only the trailing `windowSec` ending at edgeTs.
            while left < right && edgeTs - sorted[left].ts > windowSec { left += 1 }
            // Thinning stride: skip emitting until at least `stepSec` has passed since the last emitted point.
            if stepSec > 0, let last = lastEmitTs, edgeTs - last < stepSec { continue }
            // Clean the window's raw R-R values with the shared range + Malik ectopic pipeline, then
            // require enough survivors before trusting a windowed rMSSD.
            let windowRaw = sorted[left...right].map { Double($0.rrMs) }
            let clean = cleanRR(windowRaw)
            guard clean.count >= minBeatsPerWindow, let r = rmssdRaw(clean) else { continue }
            out.append(RollingRmssdPoint(ts: edgeTs, rmssd: r))
            lastEmitTs = edgeTs
        }
        return out
    }

    // MARK: - R-R integrity diagnostics (#257)

    /// What a night's R-R coverage pair says about the capture (#550).
    ///
    /// `rrCoverage` above 1.0 is physically impossible, and `collapsedCoverage` previews what a
    /// same-second de-dup would leave. Reading the two together is what tells you WHICH over-count you
    /// have — a rule that until now lived only in a comment, so anyone triaging an "HRV reads ~2× high"
    /// report had to know it. Encoding it means the log states the conclusion instead of the evidence.
    public enum RrCoverageVerdict: String, Equatable, Sendable {
        /// At or near 1.0 — the beat-time fits the wall clock. Nothing to explain.
        case plausible
        /// Materially BELOW 1.0: beat-time is missing from the window. Not a clean night, and not an
        /// over-count either — the analysis window silently is not the window it appears to be, because
        /// beats that never arrived cannot be distinguished from beats that were never there. Same
        /// principle as `unmeasurable` below: claiming a capture was fine when a seventh of it is absent
        /// is the opposite of what this verdict exists to do. (#977)
        case underCovered
        /// Over-covered, but collapsing same-second duplicates brings it back in range: the extra beats
        /// share a timestamp, so a de-dup at that granularity would fix it.
        case sameSecondOverCount
        /// Over-covered AND still over-covered after the same-second collapse: the duplicates straddle
        /// second boundaries, so a same-second de-dup would NOT be enough.
        case crossSecondOverCount
        /// No usable coverage figure — `rrCoverage` returns 0 for < 2 beats or a zero span. Absence of
        /// evidence, NOT a clean night: reporting those as `plausible` would claim the capture was fine
        /// when nothing was measurable, which is the opposite of what this verdict exists to do.
        case unmeasurable
    }

    /// Tolerance BELOW 1.0 treated as "fits", the mirror of `coveragePlausibleCeiling`. Same allowance,
    /// same caveat: a ROUNDING allowance rather than a tuned threshold, because whole-second timestamps
    /// under-report as easily as they over-report. Where the real boundary sits still needs coverage
    /// figures from several wearers — `IntelligenceEngine` already logs `coverage` in the `hrv diag`
    /// line, so that distribution can be gathered from traces that already exist. (#977)
    ///
    /// Deliberately symmetric rather than fitted: picking a number between the reported 0.859 and the
    /// 0.89 of #803's capture would be choosing a threshold to match one corpus, which is what the
    /// ceiling's own comment warns against.
    ///
    /// DERIVED rather than written as 0.90 so it cannot drift if the ceiling moves. IEEE-754 makes the
    /// result 0.8999999999999999, not exactly 0.90, because 1.10 - 1.0 is not exactly 0.10 — harmless
    /// (a night at exactly 0.90 is still above it) and identical on both platforms, since both fold the
    /// same double arithmetic. Symmetry with the ceiling is the property worth keeping; the last bit is
    /// not.
    public static let coveragePlausibleFloor: Double = 1.0 - (coveragePlausibleCeiling - 1.0)

    /// Tolerance above 1.0 treated as "fits". R-R timestamps are whole seconds while beats are not, so a
    /// clean night can round fractionally over. This is a ROUNDING allowance, deliberately not a tuned
    /// threshold — where the real boundary sits needs coverage figures from several wearers, which is the
    /// point of logging the verdict in the first place.
    public static let coveragePlausibleCeiling: Double = 1.10

    /// Classify a night from its coverage pair. Pure. Byte-parity twin of Kotlin `classifyCoverage`.
    /// Both platforms use the NEGATED `>` form rather than `<=` so a non-finite input lands identically:
    /// every IEEE-754 comparison with NaN is false, so `<=` and `>` are not each other's inverse there and
    /// the twins would otherwise disagree. NaN falls to `.unmeasurable` on both.
    public static func classifyCoverage(coverage: Double, collapsed: Double) -> RrCoverageVerdict {
        guard coverage > 0 else { return .unmeasurable }
        // #977: the floor is tested BEFORE the ceiling so the negated-`>` NaN convention above still
        // holds — a non-finite coverage has already left via `unmeasurable` and cannot reach here.
        guard coverage >= coveragePlausibleFloor else { return .underCovered }
        guard coverage > coveragePlausibleCeiling else { return .plausible }
        return collapsed > coveragePlausibleCeiling ? .crossSecondOverCount : .sameSecondOverCount
    }

    /// Total heartbeat-time (sum of NN intervals, ms) ÷ wall-clock span of the R-R window (ms). A value
    /// > ~1.0 is physically impossible — you can't record more beat-time than elapsed time — so it
    /// directly flags DOUBLE-COUNTED / overlapping R-R (e.g. a live + historical merge storing the same
    /// beat under two timestamps, which inflates HRV and drags resting HR down, #257). Returns 0 for
    /// < 2 beats or a zero span. Byte-parity twin of Kotlin `HrvAnalyzer.rrCoverage`.
    public static func rrCoverage(tsSec: [Int], rrMs: [Double]) -> Double {
        guard tsSec.count >= 2, !rrMs.isEmpty, let lo = tsSec.min(), let hi = tsSec.max() else { return 0 }
        let spanMs = Double(hi - lo) * 1000
        guard spanMs > 0 else { return 0 }
        return rrMs.reduce(0, +) / spanMs
    }

    /// How many R-R rows are EXACT duplicates of another — same (ts, rrMs). Extra copies of one beat;
    /// `total − distinct(ts, rrMs)`. Points at the double-insert mechanism when `rrCoverage` > 1.
    /// Byte-parity twin of Kotlin `HrvAnalyzer.duplicateBeatCount`.
    public static func duplicateBeatCount(tsSec: [Int], rrMs: [Double]) -> Int {
        struct Key: Hashable { let ts: Int; let rr: Double }
        let n = min(tsSec.count, rrMs.count)
        var seen = Set<Key>()
        var dups = 0
        for i in 0..<n where !seen.insert(Key(ts: tsSec[i], rr: rrMs[i])).inserted { dups += 1 }
        return dups
    }

    /// #550: coverage AFTER collapsing SAME-SECOND near-duplicate beats (equal ts AND |Δrr| ≤ `rrTolMs`)
    /// to a single representative — a PREVIEW of what an R-R de-duplication fix would achieve, for the
    /// always-on #257 diag ONLY. It does NOT feed the shipped nightly HRV. On clean data (no same-second
    /// duplicates) it equals `rrCoverage`; when a live+historical merge double-stamps the same beat WITHIN
    /// one second, it falls toward ~1. If it stays well above 1, the duplication is CROSS-second (the two
    /// copies land in adjacent seconds), which a same-second collapse cannot catch — telling us the real
    /// fix must reconcile the two ingest paths rather than dedup within a second. The collapse is
    /// deliberately same-second-ONLY: R-R ts are stored at second resolution, and at rest genuine
    /// consecutive beats are ~1 s apart, so collapsing ACROSS a second would drop real beats. Deterministic
    /// (ts, rr, index) ordering. Byte-parity twin of Kotlin `HrvAnalyzer.collapsedCoverage`.
    public static func collapsedCoverage(tsSec: [Int], rrMs: [Double], rrTolMs: Double = 30) -> Double {
        let n = min(tsSec.count, rrMs.count)
        guard n >= 2 else { return 0 }
        let order = (0..<n).sorted { a, b in
            (tsSec[a], rrMs[a], a) < (tsSec[b], rrMs[b], b)
        }
        var keptTs: [Int] = []
        var keptRr: [Double] = []
        for idx in order {
            let t = tsSec[idx]
            let r = rrMs[idx]
            var dup = false
            var j = keptTs.count - 1
            while j >= 0 && keptTs[j] == t {      // inspect only beats already kept in the SAME second
                if abs(keptRr[j] - r) <= rrTolMs { dup = true; break }
                j -= 1
            }
            if !dup { keptTs.append(t); keptRr.append(r) }
        }
        return rrCoverage(tsSec: keptTs, rrMs: keptRr)
    }

    // MARK: - Helpers

    /// Median of a non-empty array. (Caller guarantees non-empty.)
    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        let n = s.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
