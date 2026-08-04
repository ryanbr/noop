import Foundation
import StrandAnalytics
import WhoopProtocol

// RecipePort — a KNOB-FOR-KNOB port of `SleepStagerV2`, and the only place in this harness where a
// staging recipe is written out rather than called.
//
// WHY A PORT EXISTS AT ALL, given the harness links the real package. Every headline number this tool
// reports for the shipped recipe comes from `StrandAnalytics.SleepStagerV2.stageSession` itself — the
// shipped file, compiled from `Packages/`, not from here. The port exists for exactly one job the shipped
// entry point cannot do: answer "what would this recipe score with THIS constant changed?". `SleepStagerV2`
// holds its constants as `static let`s, its `Epoch`/`features()` are internal to `StrandAnalytics`, and a
// benchmark that has to rebuild the app to ask about one transition row is a benchmark nobody runs twice.
// So variants — PR #987's awake row, and each of PR #348's seven components measured alone — run through
// `V2Recipe` with a `RecipeConfig`.
//
// WHAT MAKES THAT SAFE. `RecipeConfig.shipped` must reproduce `SleepStagerV2` EXACTLY, and that is not
// asserted by reading the two files side by side — it is measured. `PortValidation` stages randomised and
// degenerate nights through both paths and requires every epoch label to agree; the check runs in
// `swift test`, so it runs in CI, on every PR, with no dataset present. The instant someone edits a
// constant in `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStagerV2.swift` without editing
// `RecipeConfig.shipped`, that test goes red and says which night diverged. A port that cannot silently
// drift is a port you can quote numbers from.
//
// The recipe below is transcribed from `SleepStagerV2.swift` — same feature windows, same two-pass onset
// re-basing, same Viterbi, same tie-breaks. The ONLY intentional differences are (a) the constants become
// `RecipeConfig` fields and (b) the memo cache is dropped, which `SleepStagerV2` documents as
// behaviour-neutral (a cache miss runs exactly the uncached path).

/// Every constant `SleepStagerV2` fixes a priori, made settable so a variant can move one and leave the
/// rest of the recipe alone.
///
/// The defaults are DUPLICATED from the shipped file rather than read from it, because `SleepStagerV2`
/// keeps them internal to `StrandAnalytics`. Duplication that can drift is normally a defect; here it is
/// pinned by `PortValidation`, which fails the build the moment the two disagree on any label.
/// How the REM emission is held back around sleep onset.
enum RemLatencyMode: Equatable {
    /// #930, shipped: a penalty of `remLatencyPenalty` log-odds at sleep ONSET, decaying linearly to zero
    /// `remLatencyMinutes` later. Onset is itself a staging output, so the recipe runs Viterbi twice — once
    /// with the guard off to find onset, once with it re-based on that onset.
    case gradedFromOnset
    /// What #930 replaced: a hard step `c < 0.12 ? penalty : 0`, in the FRACTION domain and measured from
    /// the window start rather than from sleep onset, with a single Viterbi pass.
    case preNine30FractionStep
}

struct RecipeConfig: Equatable {
    // Population base rates, as log-priors.
    var priorLight: Double
    var priorDeep: Double
    var priorRem: Double
    var priorAwake: Double

    // Deep-eligibility gate on the 11-min HR-flatness percentile.
    var deepGateThresh: Double
    var deepGateSlope: Double

    // Motion thresholds, all RELATIVE to the night's own quiescent jerk floor.
    var jerkFloorMoveMult: Double
    var jerkFloorGateMult: Double
    var motionGateBoost: Double

    // RSA respiration-regularity weight.
    var respWeight: Double

    /// Dead-zone (± this z) on the cardiac terms of the AWAKE emission. 0 disables it, which is the
    /// shipped state — `dz` is then the identity, so the shipped emission is reproduced exactly.
    var awakeDeadzone: Double

    // Per-epoch log-emission coefficients.
    var deepZhv: Double, deepZhr: Double, deepZmv: Double
    var remZhv: Double, remZmv: Double, remZhr: Double
    var awakeZmv: Double, awakeZhv: Double, awakeZhr: Double

    /// Transition matrix (rows = from, cols = to).
    var transition: [String: [String: Double]]

    // The REM-latency guard (#930) and the sleep-onset rule it is measured from.
    var remLatencyPenalty: Double
    var remLatencyMinutes: Double
    var onsetSustainedEpochs: Int

    /// Which REM-latency guard the recipe runs. Shipped is `.gradedFromOnset` (#930). The pre-#930 step is
    /// kept because the reference numbers this harness was rebuilt to reproduce were measured against it —
    /// see `Variants.preNine30Guard`. It is a diagnostic, not a candidate.
    var remLatencyMode: RemLatencyMode = .gradedFromOnset

    /// The shipped recipe, as of `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStagerV2.swift`.
    static let shipped = RecipeConfig(
        priorLight: log(0.50), priorDeep: log(0.18), priorRem: log(0.22), priorAwake: log(0.10),
        deepGateThresh: 0.25, deepGateSlope: 5.0,
        jerkFloorMoveMult: 38.0, jerkFloorGateMult: 55.0, motionGateBoost: 2.0,
        respWeight: 0.6,
        awakeDeadzone: 0.0,
        deepZhv: -1.1, deepZhr: 0.0, deepZmv: -0.5,
        remZhv: 0.6, remZmv: -0.6, remZhr: 0.4,
        awakeZmv: 1.0, awakeZhv: 0.8, awakeZhr: 0.4,
        transition: [
            "deep":  ["deep": 0.86, "rem": 0.007, "light": 0.126, "awake": 0.007],
            "rem":   ["deep": 0.005, "rem": 0.88, "light": 0.10, "awake": 0.015],
            "light": ["deep": 0.06, "rem": 0.06, "light": 0.85, "awake": 0.03],
            // THE AWAKE ROW IS THE ONE LINE THAT LEGITIMATELY DIFFERS BETWEEN BRANCHES. PR #987 zeroes
            // wake→deep and wake→rem; this fork's `main` carries it and upstream's does not until the PR
            // merges. `RecipeConfig.shipped` must always describe `SleepStagerV2` AS COMPILED on this
            // branch — `PortValidation` is what enforces that, and it will fail loudly on the wrong value.
            // `Variants.pr987` reads this row and offers the other one, so the #987 comparison works from
            // either side without a second edit.
            "awake": ["deep": 0.0, "rem": 0.0, "light": 0.10, "awake": 0.90],
        ],
        remLatencyPenalty: 3.0, remLatencyMinutes: 60.0, onsetSustainedEpochs: 10,
        remLatencyMode: .gradedFromOnset)

    var baseLogPrior: [String: Double] {
        ["light": priorLight, "deep": priorDeep, "rem": priorRem, "awake": priorAwake]
    }
}

enum V2Recipe {

    static let stageNames = ["deep", "rem", "light", "awake"]

    /// Farthest seconds, relative to an epoch, that `features` reads any input. Same values the shipped
    /// stager clips with; they are a property of the feature windows, not a tunable.
    static let padLo = 330
    static let padHi = 390

    /// One 30 s epoch's recipe features. Public within the harness because the REM ablation (clock vs
    /// physiology) is fit on exactly these columns — the model comparison has to see the same evidence the
    /// recipe does, or it answers a different question.
    struct Epoch {
        let start: Int
        let hr: Double?
        let hrVar: Double?
        let hrFlat11: Double?
        let moveFrac: Double
        let jerkMax: Double
        let respReg: Double?
        let clock: Double
        let jerkScale: Double
        let minutesSinceOnset: Double
    }

    // MARK: - Entry point

    /// Stage `[start, end]` with `cfg` and return `StageSegment`s tiling the span — the same contract as
    /// `SleepStagerV2.stageSession`, minus the memo cache.
    static func stageSession(start: Int, end: Int, grav: [GravitySample], hr: [HRSample],
                             rr: [RRInterval], resp: [RespSample],
                             cfg: RecipeConfig = .shipped) -> [StageSegment] {
        let gravW = clipToWindow(grav, lo: start - padLo, hi: end + padHi, ts: { $0.ts })
        let hrW = clipToWindow(hr, lo: start - padLo, hi: end + padHi, ts: { $0.ts })
        let rrW = clipToWindow(rr, lo: start - padLo, hi: end + padHi, ts: { $0.ts })

        let gravS = gravW.sorted { $0.ts < $1.ts }
        let hrS = hrW.sorted { $0.ts < $1.ts }
        let rrS = rrW.sortedByTsStable()

        let feats = features(start: start, end: end, grav: gravS, hr: hrS, rr: rrS, cfg: cfg)
        if feats.isEmpty { return [StageSegment(start: start, end: end, stage: "light")] }
        let labels = stageEpochs(feats, cfg: cfg)

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

    /// Stage `[start, end]` and return one label per FEATURISED epoch, alongside those epochs. The scoring
    /// paths want the epoch grid the recipe actually built (an epoch with no coverage at all is skipped by
    /// `features`, and a scorer that assumed a dense grid would silently shift every later label).
    static func stageEpochsDetailed(start: Int, end: Int, grav: [GravitySample], hr: [HRSample],
                                    rr: [RRInterval], resp: [RespSample],
                                    cfg: RecipeConfig = .shipped) -> (epochs: [Epoch], labels: [String]) {
        let gravW = clipToWindow(grav, lo: start - padLo, hi: end + padHi, ts: { $0.ts })
        let hrW = clipToWindow(hr, lo: start - padLo, hi: end + padHi, ts: { $0.ts })
        let rrW = clipToWindow(rr, lo: start - padLo, hi: end + padHi, ts: { $0.ts })
        let feats = features(start: start, end: end,
                             grav: gravW.sorted { $0.ts < $1.ts },
                             hr: hrW.sorted { $0.ts < $1.ts },
                             rr: rrW.sortedByTsStable(), cfg: cfg)
        return (feats, stageEpochs(feats, cfg: cfg))
    }

    private static func clipToWindow<T>(_ samples: [T], lo: Int, hi: Int, ts: (T) -> Int) -> [T] {
        if samples.isEmpty { return samples }
        if ts(samples[0]) >= lo && ts(samples[samples.count - 1]) < hi { return samples }
        var l = 0, h = samples.count
        while l < h { let m = (l + h) / 2; if ts(samples[m]) < lo { l = m + 1 } else { h = m } }
        let start = l
        l = start; h = samples.count
        while l < h { let m = (l + h) / 2; if ts(samples[m]) < hi { l = m + 1 } else { h = m } }
        if start == 0 && l == samples.count { return samples }
        return Array(samples[start..<l])
    }

    // MARK: - Feature extraction

    static func features(start: Int, end: Int, grav: [GravitySample], hr: [HRSample],
                         rr: [RRInterval], cfg: RecipeConfig = .shipped) -> [Epoch] {
        if end <= start { return [] }
        let span = Double(max(1, end - start))

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

        var rrBy = [Int: [Double]]()
        for r in rr { rrBy[r.ts, default: []].append(Double(r.rrMs)) }

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
            if hrs.isEmpty && gseq.isEmpty { e += 30; continue }

            var jerks: [Double] = []
            for i in 1..<max(1, gseq.count) {
                let a = gseq[i - 1], b = gseq[i]
                let dx = a.0 - b.0, dy = a.1 - b.1, dz = a.2 - b.2
                jerks.append((dx * dx + dy * dy + dz * dz).squareRoot())
            }
            allJerks.append(contentsOf: jerks)
            let jerkMax = jerks.max() ?? 0.0

            let hrMean = hrs.isEmpty ? nil : hrs.reduce(0, +) / Double(hrs.count)
            let hrVar = stdOfSeconds(e - 150, e + 30 + 150)
            let hrFlat11 = stdOfSeconds(e - 330, e + 30 + 360)

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

        let jerkScale: Double = {
            if allJerks.isEmpty { return 1e-6 }
            let s = allJerks.sorted(); let n = s.count
            return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
        }()
        let moveThr = jerkScale * cfg.jerkFloorMoveMult

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

    static func respRegularity(_ beats: [(Double, Double)]) -> Double? {
        if beats.count < 12 { return nil }
        let t0 = beats.first!.0, tN = beats.last!.0
        if tN <= t0 { return nil }
        let n = Int(ceil((tN - t0) / 0.25 - 1e-9))
        if n < 16 { return nil }

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

    // MARK: - Staging

    /// Awake-emission dead-zone. Identity when `awakeDeadzone <= 0`, which is the shipped state.
    static func dz(_ z: Double, _ deadzone: Double) -> Double {
        if deadzone <= 0.0 { return z }
        if z > deadzone { return z - deadzone }
        if z < -deadzone { return z + deadzone }
        return 0.0
    }

    static func motionQuiescent(_ f: Epoch, _ cfg: RecipeConfig) -> Bool {
        f.moveFrac <= 0.0 && f.jerkMax <= f.jerkScale * cfg.jerkFloorGateMult
    }

    static func remLatencyGuard(_ minutesSinceOnset: Double, _ cfg: RecipeConfig) -> Double {
        cfg.remLatencyPenalty * min(1.0, max(0.0, 1.0 - minutesSinceOnset / cfg.remLatencyMinutes))
    }

    static func cyclePrior(_ c: Double, _ minutesSinceOnset: Double, _ cfg: RecipeConfig) -> [String: Double] {
        ["deep": 1.2 * max(0.0, 1.0 - c / 0.55),
         "rem": 1.0 * c - remLatencyGuard(minutesSinceOnset, cfg),
         "light": 0.0, "awake": 0.0]
    }

    static func sustainedSleepOnset(_ labels: [String], _ cfg: RecipeConfig) -> Int? {
        var run = 0
        for i in labels.indices {
            if labels[i] == "awake" { run = 0; continue }
            run += 1
            if run >= cfg.onsetSustainedEpochs { return i - cfg.onsetSustainedEpochs + 1 }
        }
        return nil
    }

    static func viterbi(_ emSeq: [[String: Double]], _ cfg: RecipeConfig) -> [String] {
        if emSeq.isEmpty { return [] }
        let logT = cfg.transition.mapValues { row in row.mapValues { log(max($0, 1e-9)) } }
        var V = emSeq[0]
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

    static func stageEpochs(_ feats: [Epoch], cfg: RecipeConfig = .shipped) -> [String] {
        if feats.isEmpty { return [] }
        let prior = cfg.baseLogPrior

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
            let gate = cfg.deepGateSlope * max(0.0, fpct(f.hrFlat11) - cfg.deepGateThresh)
            let awakeCardiac0 = cfg.awakeZhv * dz(zhvv, cfg.awakeDeadzone)
                + cfg.awakeZhr * dz(zhrv, cfg.awakeDeadzone)
            let awakeCardiac = motionQuiescent(f, cfg) ? min(0.0, awakeCardiac0) : awakeCardiac0
            var em: [String: Double] = [
                "deep": cfg.deepZhv * zhvv + cfg.deepZhr * zhrv + cfg.deepZmv * zmvv - gate + prior["deep"]!,
                "rem": cfg.remZhv * zhvv + cfg.remZmv * zmvv + cfg.remZhr * zhrv + prior["rem"]!,
                "light": prior["light"]!,
                "awake": cfg.awakeZmv * zmvv + awakeCardiac + prior["awake"]!,
            ]
            // In `.gradedFromOnset` the guard is DISABLED here (`.infinity` ⇒ guard = 0) and added by pass 2
            // once onset is known. In `.preNine30FractionStep` there is no onset to wait for — the step is
            // a function of the session fraction alone — so it goes in now and there is no second pass.
            let pr: [String: Double]
            switch cfg.remLatencyMode {
            case .gradedFromOnset:
                pr = cyclePrior(f.clock, .infinity, cfg)
            case .preNine30FractionStep:
                pr = ["deep": 1.2 * max(0.0, 1.0 - f.clock / 0.55),
                      "rem": 1.0 * f.clock - (f.clock < 0.12 ? cfg.remLatencyPenalty : 0.0),
                      "light": 0.0, "awake": 0.0]
            }
            for s in stageNames { em[s]! += pr[s]! }
            if f.jerkMax > f.jerkScale * cfg.jerkFloorGateMult { em["awake"]! += cfg.motionGateBoost }
            if let rg = f.respReg { let z = zrg(rg); em["deep"]! += cfg.respWeight * z; em["rem"]! -= cfg.respWeight * z }
            seq.append(em)
        }

        if cfg.remLatencyMode == .preNine30FractionStep { return viterbi(seq, cfg) }

        let provisional = viterbi(seq, cfg)
        let originMin = sustainedSleepOnset(provisional, cfg).map { feats[$0].minutesSinceOnset } ?? 0.0
        for i in feats.indices {
            seq[i]["rem"]! -= remLatencyGuard(feats[i].minutesSinceOnset - originMin, cfg)
        }
        return viterbi(seq, cfg)
    }
}
