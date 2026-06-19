import Foundation

// ResonanceEngine.swift — find a user's personal resonance-frequency breathing pace by sweeping candidate
// paces and measuring which one maximises respiratory sinus arrhythmia (RSA) amplitude. PURE + DB-free;
// the live session controller (per platform) paces each candidate via `BreathPacer` + the buzz path,
// feeds the clean R-R it ingested per pace back in here, and persists the locked pace as a pref.
//
// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L1 "Detect (the sweep)").
//
// THEORY (Lehrer/Gevirtz, approach not code): there is a personal pace — usually 4.5–7 br/min — at which
// the 0.1 Hz baroreflex and RSA align and the heart-rate oscillation amplitude peaks. We find it by
// pacing the user through candidate paces and reading the RSA response at each.
//
// RSA amplitude (per pace): the heart speeds up on the inhale and slows on the exhale; once-per-breath
// that produces a peak-to-trough swing in the instantaneous HR (60000/RR). We know each breath cycle's
// boundaries because WE paced them (from `BreathPacer`/the pace's cycle length), so we measure the mean
// peak-to-trough swing of instantaneous HR WITHIN each paced breath cycle. That mean swing is the RSA
// amplitude; it peaks at the resonance pace. RMSSD (via the shared `HRVAnalyzer`) corroborates / breaks ties.
//
// HONEST LIMITS (stated in the spec): WHOOP R-R is PPG-derived, not ECG — RSA amplitude / HF-HRV are
// ESTIMATES, never clinical readings. A pace with too few clean beats is left UNSCORED rather than
// guessed; if fewer than `minScoredPaces` score, we report "no lock" and fall back to the 5.5 br/min
// coherence pace. We never claim the pace is permanent — the caller dates it; it drifts.

public enum ResonanceEngine {

    // MARK: - Candidate paces

    /// The full sweep candidate paces (br/min), 4.5–7.0 in 0.5 steps — the resonance band.
    public static let fullSweepPaces: [Double] = [4.5, 5.0, 5.5, 6.0, 6.5, 7.0]
    /// The quick sweep (≈7 min) — the band's ends + centre.
    public static let quickSweepPaces: [Double] = [4.5, 5.5, 6.5]
    /// The coherence fallback pace used when no resonance pace can be locked.
    public static let fallbackBpm: Double = 5.5

    // MARK: - Tunables

    /// Drop this many leading seconds of each pace as a settling transient before scoring (spec ~30 s).
    public static let transientDropSeconds: Int = 30
    /// Minimum clean beats over a pace's steady window before its RSA/RMSSD are trusted (mirrors
    /// `HRVAnalyzer.minBeats`).
    public static let minBeatsPerPace: Int = HRVAnalyzer.minBeats
    /// Minimum breath cycles with a measurable swing before a pace is scorable.
    public static let minCyclesPerPace: Int = 3
    /// Fewer than this many SCORED paces → no confident lock; fall back to `fallbackBpm`.
    public static let minScoredPaces: Int = 3

    // MARK: - Inputs / outputs

    /// One beat — a plain (ts, rrMs) pair, decoupled from the storage entities so the engine takes pure
    /// inputs (the parity twin carries the identical shape). ts is wall-clock unix SECONDS; rrMs the R-R
    /// interval in ms. The caller maps its `RRInterval` / `RrInterval` rows onto these.
    public struct RrBeat: Equatable, Sendable {
        public let ts: Int
        public let rrMs: Int
        public init(ts: Int, rrMs: Int) { self.ts = ts; self.rrMs = rrMs }
    }

    /// The clean R-R a single paced candidate produced, with the pace it was paced at. `rr` are the R-R
    /// beats ingested while pacing at `bpm`; `startTs` / `endTs` bound the paced window (the transient
    /// drop is applied relative to `startTs`).
    public struct PaceSample: Equatable, Sendable {
        public let bpm: Double
        public let rr: [RrBeat]
        public let startTs: Int
        public let endTs: Int
        public init(bpm: Double, rr: [RrBeat], startTs: Int, endTs: Int) {
            self.bpm = bpm; self.rr = rr; self.startTs = startTs; self.endTs = endTs
        }
    }

    /// The RSA / RMSSD response measured at one swept pace. `rsaAmplitude` is nil (the pace is UNSCORED)
    /// when the steady window had too few clean beats / cycles to measure honestly.
    public struct PaceScore: Equatable, Sendable {
        /// The paced breaths/min this score is for.
        public let bpm: Double
        /// Mean peak-to-trough instantaneous-HR swing per breath cycle (bpm), or nil if unscored.
        public let rsaAmplitude: Double?
        /// RMSSD over the pace's steady-window clean beats (ms), or nil.
        public let rmssd: Double?
        /// Clean beats used in the steady window.
        public let cleanBeats: Int
        /// Breath cycles that yielded a measurable swing.
        public let scoredCycles: Int
        /// Convenience: was this pace scored (RSA present)?
        public var scored: Bool { rsaAmplitude != nil }

        public init(bpm: Double, rsaAmplitude: Double?, rmssd: Double?, cleanBeats: Int, scoredCycles: Int) {
            self.bpm = bpm; self.rsaAmplitude = rsaAmplitude; self.rmssd = rmssd
            self.cleanBeats = cleanBeats; self.scoredCycles = scoredCycles
        }
    }

    /// The whole sweep result: every pace's score plus the locked pace (and whether it's a real lock or
    /// the honest fallback). `lockedBpm` is always finite (the fallback when not locked) so the UI can use
    /// it directly; `didLock` tells the copy whether to say "your pace" vs "couldn't lock today".
    public struct SweepResult: Equatable, Sendable {
        /// Per-pace scores in the order the candidates were swept.
        public let scores: [PaceScore]
        /// The selected pace (the RSA-max scored pace, or `fallbackBpm` when no confident lock).
        public let lockedBpm: Double
        /// True when a resonance pace was confidently locked; false when we fell back to coherence.
        public let didLock: Bool

        public init(scores: [PaceScore], lockedBpm: Double, didLock: Bool) {
            self.scores = scores; self.lockedBpm = lockedBpm; self.didLock = didLock
        }
    }

    // MARK: - Per-pace RSA scoring

    /// Score ONE paced candidate: clean its R-R, drop the leading transient, slice the steady window into
    /// the paced breath cycles, and measure the mean per-cycle peak-to-trough instantaneous-HR swing
    /// (RSA amplitude). RMSSD (shared `HRVAnalyzer`) corroborates. Unscorable (too few beats/cycles) →
    /// `rsaAmplitude == nil`.
    public static func scorePace(_ sample: PaceSample) -> PaceScore {
        let cycleMs = 60_000.0 / max(sample.bpm, BreathPacer.minBpm)
        let cycleSec = cycleMs / 1000.0

        // Steady window: from startTs + transient to endTs.
        let windowStart = sample.startTs + transientDropSeconds
        let steady = sample.rr
            .filter { $0.ts >= windowStart && $0.ts <= sample.endTs }
            .sorted { $0.ts < $1.ts }

        // Clean R-R (range + Malik) for both the RMSSD and the swing, so ectopic beats can't fabricate
        // an RSA swing. Cleaning operates on the rrMs values; we keep ts alongside for cycle bucketing.
        let cleanMs = HRVAnalyzer.cleanRR(steady.map { Double($0.rrMs) })
        guard cleanMs.count >= minBeatsPerPace else {
            return PaceScore(bpm: sample.bpm, rsaAmplitude: nil, rmssd: nil,
                             cleanBeats: cleanMs.count, scoredCycles: 0)
        }

        // Re-pair the cleaned values back to timestamps by matching them in order against `steady`
        // (cleaning preserves order and only drops beats), so each surviving beat keeps its ts.
        let cleanBeats = repairTimestamps(steady: steady, cleanMs: cleanMs)
        let rmssd = HRVAnalyzer.rmssdRaw(cleanMs)

        // Bucket clean beats into paced breath cycles relative to windowStart; per cycle, take the
        // peak-to-trough swing of instantaneous HR (60000/RR).
        var swings: [Double] = []
        if cycleSec > 0, let firstTs = cleanBeats.first?.ts {
            var cycleIdx = 0
            var cycleHRs: [Double] = []
            func flush() {
                if cycleHRs.count >= 2 {
                    let hi = cycleHRs.max() ?? 0
                    let lo = cycleHRs.min() ?? 0
                    swings.append(hi - lo)
                }
                cycleHRs.removeAll(keepingCapacity: true)
            }
            for beat in cleanBeats {
                let idx = Int(Double(beat.ts - firstTs) / cycleSec)
                if idx != cycleIdx { flush(); cycleIdx = idx }
                cycleHRs.append(60_000.0 / beat.rrMs)
            }
            flush()
        }

        guard swings.count >= minCyclesPerPace else {
            return PaceScore(bpm: sample.bpm, rsaAmplitude: nil, rmssd: rmssd,
                             cleanBeats: cleanMs.count, scoredCycles: swings.count)
        }
        let rsa = swings.reduce(0, +) / Double(swings.count)
        return PaceScore(bpm: sample.bpm, rsaAmplitude: rsa, rmssd: rmssd,
                         cleanBeats: cleanMs.count, scoredCycles: swings.count)
    }

    // MARK: - The sweep → locked pace

    /// Score every swept candidate and pick the resonance pace = the SCORED pace with the largest RSA
    /// amplitude (RMSSD breaks ties — higher RMSSD wins, a sanity corroboration). When fewer than
    /// `minScoredPaces` candidates scored, no confident lock: fall back to `fallbackBpm` (coherence).
    public static func sweep(_ samples: [PaceSample]) -> SweepResult {
        let scores = samples.map { scorePace($0) }
        let scored = scores.filter { $0.scored }

        guard scored.count >= minScoredPaces else {
            return SweepResult(scores: scores, lockedBpm: fallbackBpm, didLock: false)
        }
        // Max RSA amplitude; tie → higher RMSSD; final tie → slower pace (lower bpm, the calmer choice).
        let best = scored.max { a, b in
            let ra = a.rsaAmplitude ?? 0, rb = b.rsaAmplitude ?? 0
            if ra != rb { return ra < rb }
            let ma = a.rmssd ?? 0, mb = b.rmssd ?? 0
            if ma != mb { return ma < mb }
            return a.bpm > b.bpm
        }
        return SweepResult(scores: scores, lockedBpm: best?.bpm ?? fallbackBpm, didLock: true)
    }

    // MARK: - Helpers

    /// One clean beat with its timestamp restored.
    struct CleanBeat: Equatable { let ts: Int; let rrMs: Double }

    /// Re-attach timestamps to the cleaned rrMs series. Cleaning (`HRVAnalyzer.cleanRR`) preserves order
    /// and only DROPS beats, so we walk `steady` in order consuming the next match for each cleaned value.
    static func repairTimestamps(steady: [RrBeat], cleanMs: [Double]) -> [CleanBeat] {
        var out: [CleanBeat] = []
        out.reserveCapacity(cleanMs.count)
        var si = 0
        for v in cleanMs {
            while si < steady.count && Double(steady[si].rrMs) != v { si += 1 }
            if si < steady.count {
                out.append(CleanBeat(ts: steady[si].ts, rrMs: v))
                si += 1
            }
        }
        return out
    }
}
