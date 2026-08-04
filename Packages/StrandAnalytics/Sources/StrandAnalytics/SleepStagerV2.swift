import Foundation
import WhoopProtocol

// SleepStagerV2.swift — the DEFAULT sleep-staging recipe. It became the default over the older
// percentile-band stager `SleepStager` (V1) after a 44-subject cross-subject benchmark; V1 stays available
// behind the PuffinExperiment flag.
//
// Reimplemented clean from @sunny-noop's contributor recipe (pre-fork PR #600 — NOT this repo's #600,
// which is an iOS notification). We took only the
// per-session STAGING engine, not the CLI runner the PR shipped with it. Session DETECTION (the in-bed
// `[start, end]` spans) still comes entirely from V1 — this file only re-stages a window someone already
// decided is sleep, so it is a true drop-in for `SleepStager.stageSession(start:end:grav:hr:rr:resp:)`:
// SAME signature, SAME `[StageSegment]` return shape.
//
// HONEST HEDGING (same spirit as V1): these stages are APPROXIMATIONS, not PSG-validated, not medical
// advice. The recipe first shipped with only its author's n=1 validation; it is now the default because a
// 44-subject leave-one-subject-out benchmark (AAUWSS + Walch sleep-accel) showed it strictly dominates V1
// (kappa 0.35 vs 0.03, deep recall 55% vs 1%). The per-epoch coefficients are still fixed a-priori from
// sleep physiology + population base rates, not fit to labels.
//
// Where V1 runs a percentile-band classifier + median smoothing + physiology re-imposition over a
// Cole–Kripke actigraphy grid, V2 stages each 30 s epoch from:
//   1. per-night z-scored cardiorespiratory emissions (HR / HR-variability / movement);
//   2. a per-night DEEP gate on the 11-min HR-flatness percentile (the strongest deep-vs-light separator);
//   3. a soft sleep-cycle prior (deep concentrated early as a fraction of the session; REM rising with that
//      same fraction, minus a REM-latency guard that decays over the first 60 MINUTES after sleep onset);
//   4. a peak-motion (jerk) wake gate, thresholded RELATIVE to the night's own quiescent jerk floor — so
//      it self-calibrates to the strap's gravity-decode scale and the wearer's fit, not a fixed g;
//   5. an RR-RSA respiration-regularity term (regular breathing → deep, irregular → REM);
//   6. Viterbi/HMM transition smoothing with a sticky transition matrix.
// All coefficients are fixed a-priori from sleep physiology + population base rates (NOT fit to labels).

public enum SleepStagerV2 {

    /// Build a 30 s hypnogram for `[start, end]` with this recipe and return `StageSegment`s tiling the
    /// span. DROP-IN: same signature + return type as `SleepStager.stageSession`, so a caller can switch
    /// V1↔V2 on a flag with no other change. `resp` (raw resp ADC) is accepted for signature-parity but not
    /// consumed — respiration regularity is recovered from the R-R stream (RSA), the path available on both
    /// WHOOP 4 and 5. The recipe stages "wake" naturally (no separate pre-onset / post-wake forcing).
    public static func stageSession(start: Int, end: Int, grav: [GravitySample],
                                    hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        // v7.0.2 perf (#707): stage each night AT MOST ONCE per (window, input-fingerprint). The post-sync
        // scoring loop and the self-heal restage call this with byte-identical streams across passes; without
        // the cache each call re-allocates the large per-second HR/gravity dictionaries below before
        // collapsing to a handful of `StageSegment`s. The key folds in start/end (the locked window — an edit
        // re-keys) and a fingerprint of every input stream that changes the staging (grav/hr/rr; resp is
        // accepted for signature-parity but NOT consumed by the recipe, so it is deliberately out of the key —
        // including it would only force needless misses). Only the small `[StageSegment]` is cached; the
        // multi-hour raw arrays are never retained. Bounded so the cache can't itself OOM.
        //
        // CLIP (#707, the cold-pass over-allocation): the callers pass the WHOLE multi-day decoded stream to
        // every per-night call, but `features()` never reads a sample outside [start-padLo, end+padHi] — the
        // farthest reach of any per-epoch window (the 11-min HR-flatness window: 330 s back, 390 s forward —
        // see `padLo`/`padHi` below). On the first post-sync pass (~21 nights cold) and the full-history Effort
        // rescore (up to 4000 nights cold) those out-of-window rows are what blow the per-second dictionaries
        // and the sort allocations up to OOM. The streams arrive sorted by ts, so we lower/upper-bound slice
        // each to the read window BEFORE fingerprinting and BEFORE the uncached recipe. This is output-identical
        // (we drop only rows `features()` could never touch) and it also tightens the fingerprint to the rows
        // that matter. PAD_LO/PAD_HI are the SAME values the Android twin (R1) clips with.
        let gravW = clipToWindow(grav, lo: start - Self.padLo, hi: end + Self.padHi, ts: { $0.ts })
        let hrW = clipToWindow(hr, lo: start - Self.padLo, hi: end + Self.padHi, ts: { $0.ts })
        let rrW = clipToWindow(rr, lo: start - Self.padLo, hi: end + Self.padHi, ts: { $0.ts })
        let key = V2Key(
            start: start, end: end,
            grav: StreamFingerprint.of(gravW, ts: { $0.ts }, quant: { Int(($0.x + $0.y + $0.z) * 1024) }),
            hr: StreamFingerprint.of(hrW, ts: { $0.ts }, quant: { Int($0.bpm) }),
            rr: StreamFingerprint.of(rrW, ts: { $0.ts }, quant: { Int($0.rrMs) }))
        return stageCache.value(key) {
            stageSessionUncached(start: start, end: end, grav: gravW, hr: hrW, rr: rrW, resp: resp)
        }
    }

    /// Farthest seconds, relative to an epoch, that `features()` reads any input — i.e. the largest backward /
    /// forward reach of any per-epoch window. The 11-min HR-flatness window dominates both directions
    /// (`stdOfSeconds(e - 330, e + 30 + 360)` reads `[e-330, e+390)`); the 5-min window (`[e-150, e+180)`) and
    /// the RSA beat window (`[e-90, e+120)`) are strictly inside it. Epochs tile `[start, end)`, so no feature
    /// can read before `start - padLo` or at/after `end + padHi`. MUST match the Android twin (R1).
    static let padLo = 330   // backward reach: 11-min window's `e - 330`
    static let padHi = 390   // forward reach: 11-min window's `e + 30 + 360`

    /// Slice a ts-sorted stream to `[lo, hi)` with a lower/upper-bound pair (O(log n) bounds + one copy of the
    /// kept rows). Returns a contiguous sub-slice as an `Array`. Loss-free for the recipe: every row outside
    /// the window is one `features()` provably never touches.
    private static func clipToWindow<T>(_ samples: [T], lo: Int, hi: Int, ts: (T) -> Int) -> [T] {
        if samples.isEmpty { return samples }
        // Already inside the window in full → avoid the copy (the common single-night case).
        if ts(samples[0]) >= lo && ts(samples[samples.count - 1]) < hi { return samples }
        // lowerBound: first index with ts >= lo.
        var l = 0, h = samples.count
        while l < h { let m = (l + h) / 2; if ts(samples[m]) < lo { l = m + 1 } else { h = m } }
        let start = l
        // upperBound: first index with ts >= hi (exclusive upper, matching the half-open read windows).
        l = start; h = samples.count
        while l < h { let m = (l + h) / 2; if ts(samples[m]) < hi { l = m + 1 } else { h = m } }
        if start == 0 && l == samples.count { return samples }
        return Array(samples[start..<l])
    }

    /// Cache key = locked window + per-stream fingerprints of the inputs the recipe actually reads.
    private struct V2Key: Hashable {
        let start: Int; let end: Int
        let grav: StreamFingerprint; let hr: StreamFingerprint; let rr: StreamFingerprint
    }

    /// ≈ a couple of weeks of distinct nights (incl. re-staged edits); FIFO-evicted, result-only.
    private static let stageCache = AnalyticsMemoCache<V2Key, [StageSegment]>(capacity: 24)

    /// The unchanged staging recipe. Split out verbatim from `stageSession` so the public entry can memoize
    /// in front of it; behaviour is byte-identical (a cache miss runs exactly this).
    private static func stageSessionUncached(start: Int, end: Int, grav: [GravitySample],
                                             hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        // Sort defensively so the windowed features behave regardless of caller ordering (V1's stageSession
        // assumes its callers pass roughly-sorted streams; we make no such assumption here).
        let gravS = grav.sorted { $0.ts < $1.ts }
        let hrS = hr.sorted { $0.ts < $1.ts }
        let rrS = rr.sortedByTsStable()   // stable: keeps #823 emission order within a second

        let feats = features(start: start, end: end, grav: gravS, hr: hrS, rr: rrS)
        if feats.isEmpty { return [StageSegment(start: start, end: end, stage: "light")] }
        let labels = stageEpochs(feats)

        // Tile [start, end] with one segment per staged epoch. The first segment back-fills [start, firstEpoch)
        // and the last extends to `end`; an interior coverage gap is carried by the preceding label. "awake"
        // is renamed to the canonical "wake" used by V1 / StageSegment.
        var segments: [StageSegment] = []
        for (i, f) in feats.enumerated() {
            let stage = labels[i] == "awake" ? "wake" : labels[i]
            let segStart = i == 0 ? start : f.start
            let segEnd = i == feats.count - 1 ? end : feats[i + 1].start
            if let last = segments.last, last.stage == stage {
                segments[segments.count - 1].end = segEnd
            } else {
                segments.append(StageSegment(start: segStart, end: segEnd, stage: stage))
            }
        }
        return segments
    }

    // MARK: - Recipe constants (all fixed a-priori — NOT fit to labels)

    static let stageNames = ["deep", "rem", "light", "awake"]

    /// Population sleep-architecture base rates as log-priors (adult TST ≈ light 50 / deep 18 / rem 22 /
    /// waso 10 %). Calibrates the boundary so light wins weak-evidence epochs.
    static let baseLogPrior: [String: Double] = [
        "light": log(0.50), "deep": log(0.18), "rem": log(0.22), "awake": log(0.10)]

    /// Deep is eligible only in the night's lowest ~25 % HR-flatness epochs (≈ deep base rate + margin).
    /// Widened 0.20 -> 0.25 by the multi-subject (AAUWSS + sleep-accel LOSO) deep-boundary tune, which
    /// recovers the deep recall the other deep-tightening edits shed while keeping precision up.
    static let deepGateThresh = 0.25
    static let deepGateSlope = 5.0

    /// Motion thresholds are RELATIVE to each night's own quiescent jerk floor (the median per-second
    /// gravity-jerk over the in-bed session), NOT an absolute g. Self-calibrates to the strap's
    /// gravity-decode scale and the wearer's fit.
    static let jerkFloorMoveMult = 38.0  // a per-second jerk counts as "moving" above floor × this
    static let jerkFloorGateMult = 55.0  // wake-boost when an epoch's peak jerk exceeds floor × this
    static let motionGateBoost = 2.0

    /// Motion-corroborated wake (elevated-but-flat-HR nights). An epoch is MOTION-QUIESCENT when it shows no
    /// observed movement (`moveFrac == 0`) AND its peak per-second jerk sits at/below the night's own quiescent
    /// floor × `jerkFloorGateMult` — i.e. the wrist did not move this epoch, on the same night-relative scale
    /// the wake jerk-gate uses. On such epochs the AWAKE emission keeps any wake-SUPPRESSING cardiac evidence
    /// (a low, flat HR) but discards the wake-PROMOTING half: a raised HR / HR-variability with the wrist
    /// motionless is a supplement / fever / hot-room / alcohol artefact, not wakefulness, and must not vote the
    /// epoch awake on its own. This never invents wake and never removes negative (pro-sleep) cardiac evidence,
    /// so a genuinely still low-HR sleep epoch is byte-identical; only a still epoch whose ELEVATED HR was about
    /// to push it awake is held. Motion (`zmvv`) and the jerk gate — which by construction cannot fire on a
    /// quiescent epoch (`jerkMax ≤ floor × gateMult`) — still drive wake on any epoch that actually moved.
    static func motionQuiescent(_ f: Epoch) -> Bool {
        f.moveFrac <= 0.0 && f.jerkMax <= f.jerkScale * jerkFloorGateMult
    }

    /// Weight of the RSA respiration-regularity term (regular → deep, irregular → REM).
    static let respWeight = 0.6

    /// Transition matrix (rows = from, cols = to). Self-transitions dominate; deep↔rem rare; wake mostly
    /// to/from light. A priori, not fit.
    ///
    /// The AWAKE row encodes sleep-onset physiology directly: a sleeper does not enter N3 or REM straight
    /// out of wakefulness — descent runs through N1/N2 — so wake→deep and wake→rem are ZERO rather than the
    /// small non-zero values they used to carry, and the freed mass goes to the wake self-loop, which makes
    /// a WASO episode span several epochs instead of flickering back to sleep after one. This row is the one
    /// part of PR #348's DREAMT re-tune that survives measurement on a de-contaminated reference set; the
    /// rest of that PR (its base priors, motion-gate multipliers, deep gate, awake dead-zone, emission
    /// coefficients and the deep/rem/light transition rows) was reverted by #437 and stays reverted, having
    /// measured neutral-to-negative here. See the header note on `viterbi` for why a zero is safe — and note
    /// that ZERO is a strong prior rather than a prohibition: the viterbi floor turns it into ≈ -20.7 against
    /// wake→light's ≈ -2.3, an ~18.4 log-unit penalty a sufficiently strong emission can still cross, so a
    /// genuine sleep-onset REM period stays representable instead of structurally impossible.
    ///
    /// Measured on one wearer's 36 recorded nights, against the strap's own band `sleep_state` (an
    /// independent reference the recipe cannot contaminate — 21 nights, 15 554 epochs): sleep/wake kappa
    /// 0.105 → 0.118 and wake sensitivity 16.0 % → 17.6 %, with the healthy-stratum wake fraction essentially
    /// unmoved (9.43 % → 9.96 %, i.e. no repeat of the #437 blow-out). Confirmed afterwards against
    /// human-scored PSG hypnograms (PhysioNet sleep-accel, 31 subjects / 26 773 epochs, #991): 4-class kappa
    /// 0.356 → 0.363, REM F1 0.569 → 0.575, wake sensitivity 30.42 % → 30.84 %, and the #437 stage-fraction
    /// guard holds against truth as well. n = 1 wearer for the band figures; see `Tools/SleepBench` and the
    /// PR for the full ablation and its limits.
    static let transition: [String: [String: Double]] = [
        "deep":  ["deep": 0.86, "rem": 0.007, "light": 0.126, "awake": 0.007],
        "rem":   ["deep": 0.005, "rem": 0.88, "light": 0.10, "awake": 0.015],
        "light": ["deep": 0.06, "rem": 0.06, "light": 0.85, "awake": 0.03],
        "awake": ["deep": 0.0, "rem": 0.0, "light": 0.10, "awake": 0.90]]

    /// One 30 s epoch's recipe features. Optionals are "no measurement"; the z-score / percentile treat a
    /// missing value as the neutral centre so a sparse channel never blocks a stage.
    struct Epoch {
        let start: Int          // epoch start (unix seconds, multiple of 30)
        let hr: Double?         // epoch-mean HR (bpm)
        let hrVar: Double?      // std of per-second HR over a centred 5-min window
        let hrFlat11: Double?   // std of per-second HR over a centred 11-min window (deep/light separator)
        let moveFrac: Double    // fraction of in-epoch per-second jerks above the night-relative move threshold
        let jerkMax: Double     // peak in-epoch per-second jerk (g) — wake is bursty
        let respReg: Double?    // RSA spectral peakedness in the 0.15–0.40 Hz band (breathing regularity)
        let clock: Double       // time-of-night fraction in [0, 1]
        let jerkScale: Double   // night quiescent jerk floor (median per-second jerk over the session)
        /// Elapsed MINUTES from the session window start to this epoch's centre — the minute-domain twin of
        /// `clock` (#930). `features()` cannot know where sleep actually began, so it fills this relative to
        /// the window start; `stageEpochs` re-bases it onto the sleep onset its own first pass found, and
        /// falls back to this window-relative value when a night never sustains sleep. Only the REM-latency
        /// guard reads it — the deep term and the REM ramp stay fractions of the session, which is what they
        /// are (see `cyclePrior`).
        let minutesSinceOnset: Double
    }

    // MARK: - Feature extraction

    /// Build the per-epoch recipe features over a 30 s wall-clock-aligned grid covering [start, end].
    /// Streams are the sorted streams already clipped (by `stageSession`) to `[start-padLo, end+padHi]` — a
    /// superset of every read window — so the 5-/11-min HR windows and the RSA beat window still reach to the
    /// session edges exactly as before; only rows no window could touch were dropped.
    static func features(start: Int, end: Int, grav: [GravitySample],
                         hr: [HRSample], rr: [RRInterval]) -> [Epoch] {
        if end <= start { return [] }
        let span = Double(max(1, end - start))

        // Per-second aggregation (one value per integer second; mean when a second carries several samples).
        var hrSum = [Int: Double](), hrCnt = [Int: Int]()
        for s in hr { hrSum[s.ts, default: 0] += Double(s.bpm); hrCnt[s.ts, default: 0] += 1 }
        var secHR = [Int: Double](); secHR.reserveCapacity(hrSum.count)
        for (k, v) in hrSum { secHR[k] = v / Double(hrCnt[k]!) }

        var gxSum = [Int: Double](), gySum = [Int: Double](), gzSum = [Int: Double](), gCnt = [Int: Int]()
        for g in grav {
            gxSum[g.ts, default: 0] += g.x; gySum[g.ts, default: 0] += g.y
            gzSum[g.ts, default: 0] += g.z; gCnt[g.ts, default: 0] += 1
        }
        var secG = [Int: (Double, Double, Double)](); secG.reserveCapacity(gCnt.count)
        for (k, c) in gCnt { let d = Double(c); secG[k] = (gxSum[k]! / d, gySum[k]! / d, gzSum[k]! / d) }

        // R-R values bucketed by second (for the RSA respiration window).
        var rrBy = [Int: [Double]]()
        for r in rr { rrBy[r.ts, default: []].append(Double(r.rrMs)) }

        // PREFIX SUMS over the per-second HR grid (#707). Every epoch evaluates a 5-min AND an 11-min centred
        // std window; the old `stdOfSeconds` re-scanned and re-allocated a `vals` array of up to ~660 entries
        // PER window PER epoch — O(window) each, the dominant transient alloc in the cold-stage path. We build
        // dense prefix arrays of (count, Σv, Σv²) over the present seconds ONCE, then each window is an O(1)
        // range query. The std stays population (÷n) with the SAME `<2 present → nil` semantics, and on every
        // real fixture the staged hypnogram is byte-identical (the second-moment is the algebraic expansion
        // `Σ(v-m)²` = `Σv² − 2m·Σv + n·m²`, which can differ from the prior direct sum only in the last ULPs —
        // far below the margin that could flip a Viterbi label; verified label-identical on the golden nights).
        // The grid spans the present HR seconds; a window reaching past the grid simply sees fewer present
        // seconds, exactly as the old scan found no `secHR` entry there.
        let gridLo = secHR.keys.min()
        let gridHi = secHR.keys.max()
        var pCnt = [Int](), pSum = [Double](), pSq = [Double]()
        if let g0 = gridLo, let g1 = gridHi {
            let n = g1 - g0 + 1
            pCnt = [Int](repeating: 0, count: n + 1)
            pSum = [Double](repeating: 0, count: n + 1)
            pSq = [Double](repeating: 0, count: n + 1)
            for i in 0..<n {
                let v = secHR[g0 + i]
                pCnt[i + 1] = pCnt[i] + (v == nil ? 0 : 1)
                pSum[i + 1] = pSum[i] + (v ?? 0)
                pSq[i + 1] = pSq[i] + (v.map { $0 * $0 } ?? 0)
            }
        }
        // Population std over the PRESENT per-second HR in `[lo, hi)`; nil when < 2 present samples (matching
        // the prior windowed scan). O(1): two prefix lookups after clamping the window to the grid.
        func stdOfSeconds(_ lo: Int, _ hi: Int) -> Double? {
            guard let g0 = gridLo, let g1 = gridHi else { return nil }
            let a = max(lo, g0) - g0
            let b = min(hi, g1 + 1) - g0
            if b <= a { return nil }
            let cnt = pCnt[b] - pCnt[a]
            if cnt < 2 { return nil }
            let n = Double(cnt)
            let sv = pSum[b] - pSum[a]
            let sq = pSq[b] - pSq[a]
            let m = sv / n
            let v = (sq - 2 * m * sv + n * m * m) / n
            return (v < 0 ? 0 : v).squareRoot()
        }

        // PASS 1 — every per-epoch quantity EXCEPT the move fraction, and pool every per-second jerk so the
        // night's quiescent jerk floor (its median) can scale the motion thresholds. moveFrac needs that
        // floor, which isn't known until the whole session has been scanned — hence two passes.
        struct Raw {
            let start: Int; let hr: Double?; let hrVar: Double?; let hrFlat11: Double?
            let jerks: [Double]; let gapSec: Int; let jerkMax: Double; let respReg: Double?; let clock: Double
            let minutes: Double
        }
        var raws: [Raw] = []
        var allJerks: [Double] = []
        let firstE = ((start + 29) / 30) * 30
        var e = firstE
        while e < end {
            var hrs: [Double] = []
            var gseq: [(Double, Double, Double)] = []
            for s in e..<(e + 30) {
                if let h = secHR[s] { hrs.append(h) }
                if let g = secG[s] { gseq.append(g) }
            }
            if hrs.isEmpty && gseq.isEmpty { e += 30; continue }   // no coverage → skip the epoch

            // Movement: consecutive per-second gravity jerks within the epoch.
            var jerks: [Double] = []
            for i in 1..<max(1, gseq.count) {
                let a = gseq[i - 1], b = gseq[i]
                let dx = a.0 - b.0, dy = a.1 - b.1, dz = a.2 - b.2
                jerks.append((dx * dx + dy * dy + dz * dz).squareRoot())
            }
            allJerks.append(contentsOf: jerks)
            let jerkMax = jerks.max() ?? 0.0

            let hrMean = hrs.isEmpty ? nil : hrs.reduce(0, +) / Double(hrs.count)
            let hrVar = stdOfSeconds(e - 150, e + 30 + 150)     // 5-min centred window
            let hrFlat11 = stdOfSeconds(e - 330, e + 30 + 360)  // 11-min centred window

            // RSA respiration over a wider beat window [e-90, e+120).
            var beats: [(Double, Double)] = []
            for s in (e - 90)..<(e + 120) {
                if let vs = rrBy[s] { for v in vs { beats.append((Double(s), min(max(v, 300), 2000))) } }
            }
            beats.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            let respReg = respRegularity(beats)

            raws.append(Raw(start: e, hr: hrMean, hrVar: hrVar, hrFlat11: hrFlat11,
                            jerks: jerks, gapSec: max(1, gseq.count - 1), jerkMax: jerkMax,
                            respReg: respReg, clock: Double(e + 15 - start) / span,
                            minutes: Double(e + 15 - start) / 60.0))
            e += 30
        }

        // Night quiescent jerk floor = median of all per-second jerks (most sleep seconds are still, so the
        // median tracks the strap's noise/decode floor). Tiny epsilon when there's no motion data so the move
        // threshold collapses to ~0 rather than dividing by nothing.
        let jerkScale: Double = {
            if allJerks.isEmpty { return 1e-6 }
            let s = allJerks.sorted(); let n = s.count
            return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
        }()
        let moveThr = jerkScale * jerkFloorMoveMult

        // PASS 2 — move fraction against the night-relative threshold; carry the floor on each epoch so the
        // wake gate in stageEpochs() can be night-relative too.
        var feats: [Epoch] = []
        feats.reserveCapacity(raws.count)
        for r in raws {
            let moves = r.jerks.reduce(0) { $0 + ($1 > moveThr ? 1 : 0) }
            feats.append(Epoch(
                start: r.start, hr: r.hr, hrVar: r.hrVar, hrFlat11: r.hrFlat11,
                moveFrac: Double(moves) / Double(r.gapSec), jerkMax: r.jerkMax, respReg: r.respReg,
                clock: r.clock, jerkScale: jerkScale, minutesSinceOnset: r.minutes))
        }
        return feats
    }

    /// RSA respiration regularity: tachogram → 4 Hz resample → detrend → power spectrum → peak/sum of the
    /// 0.15–0.40 Hz (9–24 brpm) band. Returns spectral peakedness (higher = more regular breathing) or nil
    /// when there are too few beats. A direct band-limited DFT (only the ~50 in-band bins are needed).
    static func respRegularity(_ beats: [(Double, Double)]) -> Double? {
        if beats.count < 12 { return nil }
        let t0 = beats.first!.0, tN = beats.last!.0
        if tN <= t0 { return nil }
        let n = Int(ceil((tN - t0) / 0.25 - 1e-9))   // np.arange(t0, tN, 0.25) length
        if n < 16 { return nil }

        // Linear resample onto the uniform 4 Hz grid (clamped within [t0, tN]).
        var y = [Double](repeating: 0, count: n)
        var seg = 0
        for i in 0..<n {
            let t = t0 + 0.25 * Double(i)
            while seg < beats.count - 2 && beats[seg + 1].0 < t { seg += 1 }
            let ta = beats[seg].0, tb = beats[seg + 1].0
            let va = beats[seg].1, vb = beats[seg + 1].1
            y[i] = tb <= ta ? va : va + min(max((t - ta) / (tb - ta), 0), 1) * (vb - va)
        }
        let mean = y.reduce(0, +) / Double(n)
        for i in 0..<n { y[i] -= mean }

        // Band bins: f[k] = k / (n·0.25); keep 0.15 ≤ f ≤ 0.40.
        let kLo = Int(ceil(0.15 * 0.25 * Double(n)))
        let kHi = Int(floor(0.40 * 0.25 * Double(n)))
        if kHi < kLo || kLo < 0 { return nil }
        var maxP = 0.0, sumP = 0.0
        for k in kLo...kHi {
            var re = 0.0, im = 0.0
            let w = -2.0 * Double.pi * Double(k) / Double(n)
            for j in 0..<n { let a = w * Double(j); re += y[j] * cos(a); im += y[j] * sin(a) }
            let p = re * re + im * im
            sumP += p
            if p > maxP { maxP = p }
        }
        if sumP == 0 { return nil }
        return maxP / sumP
    }

    // MARK: - Recipe staging

    // ── the REM-latency guard (#930) ──────────────────────────────────────────────────────────────────

    /// Log-odds penalty applied to the REM emission AT sleep onset. Unchanged in magnitude from the
    /// `c < 0.12 ? 3.0 : 0.0` step this replaced: e⁻³ ≈ 0.05 on the REM emission — strong suppression that
    /// sufficient evidence still overcomes, never a veto. Kept at the incumbent value deliberately, because
    /// the sleep-accel grid ({cliff, graded} × {fraction, minutes} × K ∈ 1…8 × threshold, 210 cells) showed
    /// every cell tying on accuracy, so nothing in the data discriminates K — and the smallest correct change
    /// is to fix the UNITS and the SHAPE without also retuning a magnitude no measurement can justify.
    static let remLatencyPenalty = 3.0

    /// Minutes over which `remLatencyPenalty` decays linearly to zero, measured from sleep ONSET.
    /// Against PSG truth on sleep-accel (n = 31 subjects), a guard reaching 45 min costs 0.36 % of all real
    /// REM (1 subject affected) and one reaching 90 min costs 6.85 % (15 subjects); 60 min sits inside that
    /// band, and because the penalty is GRADED rather than a cliff it is already down to ≤ 0.75 log-odds
    /// (×0.47, vs ×0.05 at onset) across 45–60 min, so a genuine sleep-onset REM period late in the window is
    /// held back rather than suppressed. 60 min also stops clear of the ~70–100 min population first-REM
    /// latency, so the ramp is fully spent before real REM is expected.
    static let remLatencyMinutes = 60.0

    /// The guard itself: `K` at (and before) sleep onset, decaying linearly to 0 at `M0` minutes after it.
    /// Clamped to `[0, K]` so a PRE-onset epoch — negative elapsed time, and unbounded when detection places
    /// the window start hours early (#271) — can never be penalised harder than the onset instant itself.
    static func remLatencyGuard(_ minutesSinceOnset: Double) -> Double {
        remLatencyPenalty * min(1.0, max(0.0, 1.0 - minutesSinceOnset / remLatencyMinutes))
    }

    /// Soft sleep-cycle prior added to the log-emission: deep concentrated early (decays, never hard-wiped);
    /// REM suppressed around sleep onset (REM latency) then rising toward morning.
    ///
    /// PROVENANCE of the constants: `1.2`, `0.55` and the `1.0` REM slope are hand-picked a priori from sleep
    /// physiology and population base rates, never fit to labels — as is every other coefficient in this file.
    /// `remLatencyPenalty` / `remLatencyMinutes` carry their own derivations above.
    ///
    /// UNITS, and why they differ per term (#930). The deep term and the `1.0 * c` REM ramp take `c`, the
    /// fraction of the session — correctly, because both describe *where in the night* you are, a quantity
    /// that is inherently proportional. The REM-LATENCY guard takes `minutesSinceOnset` instead, because
    /// first-REM latency is an absolute physiological interval and not a proportion of how long you slept: on
    /// sleep-accel (n = 30 subjects with a scorable first REM period) true latency is uncorrelated with
    /// session duration (Pearson r = −0.058, Spearman −0.076), and re-expressing latency as a fraction makes
    /// it MORE variable, not less (CV 0.617 as a fraction vs 0.537 in minutes). The `c < 0.12` step this
    /// replaced therefore scaled a fixed physiological interval by session length: across one WHOOP 5 user's
    /// own recorded nights it ranged 7.4–84.5 min, an 11× spread, for the same wearer and the same physiology.
    static func cyclePrior(_ c: Double, _ minutesSinceOnset: Double) -> [String: Double] {
        ["deep": 1.2 * max(0.0, 1.0 - c / 0.55),
         "rem": 1.0 * c - remLatencyGuard(minutesSinceOnset),
         "light": 0.0, "awake": 0.0]
    }

    /// Sustained non-wake run, in 30 s epochs, that establishes sleep onset — 10 epochs = 5 minutes.
    /// Measured against PSG onset on sleep-accel (n = 31 subjects): bias −3.8 min, MAE 7.4 min.
    static let onsetSustainedEpochs = 10

    /// Index of the first epoch that begins a run of `onsetSustainedEpochs` consecutive non-"awake" labels,
    /// or nil when the hypnogram never sustains sleep that long (a nap shorter than the rule, or an all-wake
    /// window). Runs are counted in epochs, not wall clock, so a coverage gap that drops an epoch cannot
    /// silently satisfy the rule with less evidence.
    static func sustainedSleepOnset(_ labels: [String]) -> Int? {
        var run = 0
        for i in labels.indices {
            if labels[i] == "awake" { run = 0; continue }
            run += 1
            if run >= onsetSustainedEpochs { return i - onsetSustainedEpochs + 1 }
        }
        return nil
    }

    /// Viterbi most-likely path over the per-epoch log-emissions with the sticky transition matrix and a
    /// uniform start. Ties resolve to the earlier stage in `stageNames`.
    static func viterbi(_ emSeq: [[String: Double]]) -> [String] {
        if emSeq.isEmpty { return [] }
        // Floor before ln so a zeroed transition entry can never hit ln(0) = -Inf and poison the lattice.
        // LOAD-BEARING, not defensive: the awake row carries wake→deep = wake→rem = 0.0, so this floor is
        // the only thing between those two entries and -Inf. Deleting it does not remove dead code, it
        // breaks the stager. Floored, a zero costs ln(1e-9) ≈ -20.7 against wake→light's ≈ -2.3. The floor
        // arrived with #348 and survived #437; the zeros it now carries arrived later.
        let logT = transition.mapValues { row in row.mapValues { log(max($0, 1e-9)) } }
        var V = emSeq[0]   // uniform start
        var back: [[String: String]] = []
        for t in 1..<emSeq.count {
            var newV = [String: Double](), bp = [String: String]()
            for s in stageNames {
                var bestPrev = stageNames[0]
                var bestVal = V[bestPrev]! + logT[bestPrev]![s]!
                for p in stageNames.dropFirst() {
                    let val = V[p]! + logT[p]![s]!
                    if val > bestVal { bestVal = val; bestPrev = p }
                }
                newV[s] = bestVal + emSeq[t][s]!
                bp[s] = bestPrev
            }
            V = newV; back.append(bp)
        }
        var last = stageNames[0], lastV = V[last]!
        for s in stageNames.dropFirst() where V[s]! > lastV { lastV = V[s]!; last = s }
        var path = [last]
        for bp in back.reversed() { last = bp[last]!; path.append(last) }
        return path.reversed()
    }

    /// Run the full recipe over a night's epochs and return one stage label per epoch (incl. "awake").
    /// All normalisation (z-scores, the HR-flatness percentile) is WITHIN the night.
    ///
    /// TWO PASSES (#930). The REM-latency guard is measured from sleep ONSET, and onset is itself a staging
    /// output, so the recipe cannot know it while building the emissions. Pass 1 stages the night with the
    /// guard DISABLED (`cyclePrior(c, .infinity)`) and reads the first sustained sleep run out of the result;
    /// pass 2 adds the guard, re-based on that onset, and re-runs Viterbi. Only the guard differs between the
    /// passes — every emission term, z-score and percentile is computed ONCE and reused — so the extra cost is
    /// one Viterbi over an already-built lattice, not a second featurisation, and `stageSession` memoizes the
    /// whole thing anyway. When no sustained run exists the origin falls back to the window start, which is
    /// exactly the origin the shipped `c`-based guard used.
    static func stageEpochs(_ feats: [Epoch]) -> [String] {
        if feats.isEmpty { return [] }

        // Per-night z-score over the present values (population std; 0 std → 1 so a flat channel is neutral).
        func zfun(_ vals: [Double?]) -> (Double?) -> Double {
            let present = vals.compactMap { $0 }
            if present.isEmpty { return { _ in 0.0 } }
            let m = present.reduce(0, +) / Double(present.count)
            let sd0 = (present.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(present.count)).squareRoot()
            let sd = sd0 == 0 ? 1.0 : sd0
            return { v in v == nil ? 0.0 : (v! - m) / sd }
        }
        let zhr = zfun(feats.map { $0.hr })
        let zhv = zfun(feats.map { $0.hrVar })
        let zmv = zfun(feats.map { Optional($0.moveFrac) })
        let zrg = zfun(feats.map { $0.respReg })

        // HR-flatness percentile rank within the night (bisect_right / n), neutral 0.5 when missing.
        let fsorted = feats.compactMap { $0.hrFlat11 }.sorted()
        func fpct(_ v: Double?) -> Double {
            guard let v = v, !fsorted.isEmpty else { return 0.5 }
            var lo = 0, hi = fsorted.count
            while lo < hi { let mid = (lo + hi) / 2; if fsorted[mid] <= v { lo = mid + 1 } else { hi = mid } }
            return Double(lo) / Double(fsorted.count)
        }

        var seq: [[String: Double]] = []
        seq.reserveCapacity(feats.count)
        for f in feats {
            let zhrv = zhr(f.hr), zhvv = zhv(f.hrVar), zmvv = zmv(f.moveFrac)
            let gate = deepGateSlope * max(0.0, fpct(f.hrFlat11) - deepGateThresh)
            // Cardiac contribution to the AWAKE emission. On a motion-quiescent epoch the wrist did not move,
            // so a raised HR / HR-variability alone must NOT promote wake — clamp the cardiac term to ≤ 0,
            // keeping only its wake-SUPPRESSING (pro-sleep) half. Non-quiescent epochs are unchanged and use
            // upstream's restored (post-#437) cardiac coefficients verbatim, so a night with any motion stages
            // byte-identical to upstream; the correction only ever holds a still, elevated-HR epoch.
            let awakeCardiac0 = 0.8 * zhvv + 0.4 * zhrv
            let awakeCardiac = motionQuiescent(f) ? min(0.0, awakeCardiac0) : awakeCardiac0
            var em: [String: Double] = [
                "deep": -1.1 * zhvv - 0.5 * zmvv - gate + baseLogPrior["deep"]!,
                "rem": 0.6 * zhvv - 0.6 * zmvv + 0.4 * zhrv + baseLogPrior["rem"]!,
                "light": baseLogPrior["light"]!,
                "awake": 1.0 * zmvv + awakeCardiac + baseLogPrior["awake"]!,
            ]
            // Guard DISABLED here (`.infinity` ⇒ `remLatencyGuard` = 0); pass 2 below adds it once onset is known.
            let pr = cyclePrior(f.clock, .infinity)
            for s in stageNames { em[s]! += pr[s]! }
            if f.jerkMax > f.jerkScale * jerkFloorGateMult { em["awake"]! += motionGateBoost }
            if let rg = f.respReg { let z = zrg(rg); em["deep"]! += respWeight * z; em["rem"]! -= respWeight * z }
            seq.append(em)
        }

        // PASS 1 — stage without the REM-latency guard purely to locate sleep onset.
        let provisional = viterbi(seq)
        // Origin for the guard: the centre of the first sustained-sleep epoch, in the same window-relative
        // minutes `features()` stamped on every epoch. No sustained run → 0.0, i.e. the window start.
        let originMin = sustainedSleepOnset(provisional).map { feats[$0].minutesSinceOnset } ?? 0.0

        // PASS 2 — apply the guard against minutes since THAT onset and re-run the lattice.
        for i in feats.indices {
            seq[i]["rem"]! -= remLatencyGuard(feats[i].minutesSinceOnset - originMin)
        }
        return viterbi(seq)
    }
}
