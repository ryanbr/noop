import Foundation
import StrandAnalytics
import WhoopProtocol

// sleeppsg — score NOOP's shipped sleep stager against polysomnography.
//
// USAGE:  sleeppsg --dataset /path/to/sleep-accel-1.0.0 [--section all] [--csv out.csv] [--subjects N]
//         sleeppsg --dataset /path/to/dreamt              (DREAMT: the same sections, plus `rsa`)
//         sleeppsg --section port                        (no dataset needed — the port check alone)
//
// The dataset lives outside this repository and is always an argument. Nothing is written to it.

struct Args {
    var dataset: String?
    var section = "all"
    var csv: String?
    var subjects: Int?
    var seed: UInt64 = PortValidation.defaultSeed
}
var a = Args()
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next() {
    switch k {
    case "--dataset": a.dataset = it.next()
    case "--section": a.section = it.next() ?? a.section
    case "--csv": a.csv = it.next()
    case "--subjects": a.subjects = Int(it.next() ?? "")
    case "--seed": a.seed = UInt64(it.next() ?? "") ?? a.seed
    case "-h", "--help":
        print("""
        usage: sleeppsg --dataset <root> [--section all|port|baseline|strata|rem|variants|priors|rsa]
                        [--subjects N] [--csv <path>] [--seed <n>]

          --dataset   PhysioNet sleep-accel v1.0.0 (a folder with labels/) or DREAMT (a folder with data_64Hz/
                      and participant_info.csv). See README.md for access and the attribution each requires.
                      Never committed; read-only here. `rsa` needs R-R, so it runs on DREAMT only.
          --section   which report to print. `port` needs no dataset.
          --subjects  score only the first N subject ids (a fast smoke run; full cohort is the default).
        """)
        exit(0)
    default: FileHandle.standardError.write(Data("unknown argument \(k)\n".utf8)); exit(2)
    }
}

let wantAll = a.section == "all"
func want(_ s: String) -> Bool { wantAll || a.section == s }

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// 1. PORT VALIDATION
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("port") {
    print("""

    ================================================================================
    1. PORT VALIDATION — does this harness run the SHIPPED recipe?
    ================================================================================
    Every baseline number below comes from `StrandAnalytics.SleepStagerV2.stageSession` directly: the file
    that ships in the app, compiled from `Packages/`, called with no reimplementation in between. The
    VARIANT rows cannot work that way — `SleepStagerV2` holds its constants as `static let`s — so they run
    through `V2Recipe`, a knob-for-knob port in this tool. This section is the check that the port and the
    shipped stager are the same recipe. It runs in `swift test`, and therefore in CI, with no dataset.
    """)
    let r = PortValidation.run(seed: a.seed)
    print("""
    nights            \(r.nights)  (\(r.randomNights) randomised + \(r.degenerateNights) degenerate)
    epoch labels      \(r.matchingEpochs)/\(r.epochs) identical
    verdict           \(r.ok ? "PASS — the port reproduces the shipped stager exactly" : "FAIL")
    """)
    if !r.ok {
        for d in r.divergences.prefix(20) {
            print("  divergence  \(d.night) epoch \(d.epochIndex): shipped=\(d.shipped) port=\(d.port)")
        }
        FileHandle.standardError.write(Data("port validation FAILED — variant numbers are not trustworthy\n".utf8))
        exit(1)
    }
}

if a.section == "port" { exit(0) }

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Dataset
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

guard let datasetArg = a.dataset else {
    FileHandle.standardError.write(Data("""
    --dataset is required for every section except `port`.
    See Tools/SleepPSG/README.md for the download step and the attribution the licence requires.

    """.utf8))
    exit(2)
}
// Two datasets: DREAMT (a directory with `data_64Hz/` and `participant_info.csv`) or sleep-accel (one with
// `labels/`). Every section runs on either; the dataset decides only how subjects are read.
let dreamtRoot = Dreamt.resolveRoot(datasetArg)
let isDreamt = dreamtRoot != nil
guard let root = dreamtRoot ?? SleepAccel.resolveRoot(datasetArg) else {
    FileHandle.standardError.write(Data("no `labels/` (sleep-accel) or `data_64Hz/` (DREAMT) under \(datasetArg)\n".utf8))
    exit(2)
}

var ids = isDreamt ? Dreamt.subjectIDs(root: root) : SleepAccel.subjectIDs(root: root)
if let n = a.subjects { ids = Array(ids.prefix(n)) }
let dreamtInfo = isDreamt ? Dreamt.participants(root: root) : [:]
// Loaded concurrently — the motion files run to tens of megabytes of text each and the read dominates the
// whole run. Order is restored from `ids` afterwards so the report is identical however the threads finish.
// DREAMT's files are ~140 MB each and are held whole while parsed, so they are read in batches of four.
var loaded = [PSGSubject?](repeating: nil, count: ids.count)
let batch = isDreamt ? 4 : ids.count
for lo in stride(from: 0, to: ids.count, by: max(1, batch)) {
    let hi = min(ids.count, lo + max(1, batch))
    loaded.withUnsafeMutableBufferPointer { buf in
        let out = buf
        DispatchQueue.concurrentPerform(iterations: hi - lo) { j in
            let i = lo + j
            out[i] = isDreamt ? Dreamt.load(root: root, id: ids[i], info: dreamtInfo[ids[i]])
                              : SleepAccel.load(root: root, id: ids[i])
        }
    }
}
let subjects: [PSGSubject] = loaded.compactMap { $0 }
guard !subjects.isEmpty else {
    FileHandle.standardError.write(Data("no scorable subjects under \(root)\n".utf8)); exit(1)
}

let totalScored = subjects.reduce(0) { $0 + $1.scoredEpochs }
if isDreamt {
    let ahis = subjects.compactMap { $0.ahi }
    print("""

    ================================================================================
    2. DATASET
    ================================================================================
    PhysioNet DREAMT — Wang et al., PMLR 248 (CHIL 2024). Empatica E4 at 64 Hz beside PSG.
    Used under PhysioNet's data use agreement: never committed, and this report prints aggregates only.
    Root: \(root)

    subjects              \(subjects.count)
    PSG-scored epochs     \(totalScored)
    scored night length   median \(f(median(subjects.map { $0.scoredMinutes }), 6, 1)) min   \
    range \(f(subjects.map { $0.scoredMinutes }.min() ?? .nan, 5, 1))–\(f(subjects.map { $0.scoredMinutes }.max() ?? .nan, 5, 1)) min
    AHI (events/hour)     median \(f(median(ahis), 5, 1))   <5: \(ahis.filter { $0 < 5 }.count)   5–15: \
    \(ahis.filter { $0 >= 5 && $0 < 15 }.count)   15–30: \(ahis.filter { $0 >= 15 && $0 < 30 }.count)   ≥30: \(ahis.filter { $0 >= 30 }.count)
    beat coverage         median \(f(median(subjects.map { beatCoverage($0) }), 5, 2)) of the beats the HR implies, over scored sleep

    A SLEEP-CLINIC cohort: most subjects were referred for suspected apnoea, so wake is higher and deep and
    REM lower than on a healthy night. PR #348 fitted priors to it and PR #437 reverted that, because the
    cohort's base rates had moved into a prior applied to everyone. Read stage fractions by AHI stratum.
    The R-R stream is LIVE here: the recipe's RSA respiration term runs on the E4's inter-beat intervals.
    """)
} else {
    print("""

    ================================================================================
    2. DATASET
    ================================================================================
    PhysioNet sleep-accel v1.0.0 — Walch, Huang, Forger & Goldstein, SLEEP 42(12) zsz180 (2019).
    Licence: Open Data Commons Attribution v1.0. Root: \(root)

    subjects              \(subjects.count)
    PSG-scored epochs     \(totalScored)
    scored night length   median \(f(median(subjects.map { $0.scoredMinutes }), 6, 1)) min   \
    range \(f(subjects.map { $0.scoredMinutes }.min() ?? .nan, 5, 1))–\(f(subjects.map { $0.scoredMinutes }.max() ?? .nan, 5, 1)) min

    The R-R stream is EMPTY for every subject — this dataset carries no beat-to-beat intervals — so the
    recipe's RSA respiration term returns nil on every epoch and contributes exactly 0.0 to every emission.
    Five of the recipe's six inputs are live here; the sixth is silent, not wrong.
    """)
}

/// Beats present over the subject's PSG-scored SLEEP epochs, as a fraction of the beats its heart rate
/// implies there (Σ bpm/60 over those seconds). 1.0 is every beat; the E4 drops beats it is unsure of.
/// P(a > b) for a random a from `a` and b from `b`, ties counting half (the Mann–Whitney AUC).
func aucGreater(_ a: [Double], _ b: [Double]) -> Double {
    guard !a.isEmpty, !b.isEmpty else { return .nan }
    let all = (a.map { ($0, 0) } + b.map { ($0, 1) }).sorted { $0.0 < $1.0 }
    var rankSumA = 0.0, i = 0
    while i < all.count {
        var j = i
        while j + 1 < all.count && all[j + 1].0 == all[i].0 { j += 1 }
        let r = Double(i + j) / 2 + 1
        for k in i...j where all[k].1 == 0 { rankSumA += r }
        i = j + 1
    }
    let na = Double(a.count), nb = Double(b.count)
    return (rankSumA - na * (na + 1) / 2) / (na * nb)
}

func beatCoverage(_ s: PSGSubject) -> Double {
    var hrBy = [Int: Int]()
    for h in s.hr { hrBy[h.ts] = h.bpm }
    var beatsBy = [Int: Int]()
    for r in s.rr { beatsBy[r.ts, default: 0] += 1 }
    var have = 0.0, expect = 0.0
    for (k, st) in s.truth.enumerated() where st != nil && st != "wake" {
        let e0 = s.start + 30 * k
        for t in e0..<(e0 + 30) {
            if let b = hrBy[t] { expect += Double(b) / 60 }
            have += Double(beatsBy[t] ?? 0)
        }
    }
    return expect > 0 ? have / expect : 0
}

// Truth / prediction on the shared 30 s grid, restricted to PSG-scored epochs.
struct Scored {
    let subject: PSGSubject
    let truth: [String]
    let pred: [String]
    /// Full-grid arrays (including unscored epochs) — latency is a property of the hypnogram, not of the
    /// scored subset, so it is measured before masking.
    let fullPred: [String]
    let fullTruth: [String?]
}

func score(_ s: PSGSubject, using stage: (PSGSubject) -> [StageSegment]) -> Scored {
    let segs = stage(s)
    let pred = epochLabels(segs, start: s.start, end: s.end)
    var t: [String] = [], p: [String] = []
    for i in 0..<min(s.truth.count, pred.count) {
        guard let tv = s.truth[i] else { continue }
        t.append(tv); p.append(pred[i])
    }
    return Scored(subject: s, truth: t, pred: p, fullPred: pred, fullTruth: s.truth)
}

/// The SHIPPED stager — `StrandAnalytics.SleepStagerV2`, not the port.
func stageShipped(_ s: PSGSubject) -> [StageSegment] {
    SleepStagerV2.stageSession(start: s.start, end: s.end, grav: s.grav, hr: s.hr, rr: s.rr, resp: [])
}
func stageVariant(_ cfg: RecipeConfig) -> (PSGSubject) -> [StageSegment] {
    { s in V2Recipe.stageSession(start: s.start, end: s.end, grav: s.grav, hr: s.hr,
                                 rr: s.rr, resp: [], cfg: cfg) }
}

let shipped = subjects.map { score($0, using: stageShipped) }

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Reporting helpers
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

struct Summary {
    var conf = Confusion()
    var kappa: Double { conf.kappa }
    var accuracy: Double { conf.accuracy }
    var predPct: [String: Double] = [:]
    var truthPct: [String: Double] = [:]
    var latencyPred: [Double] = []
    var latencyTruth: [Double] = []
    var latencyPairsPred: [Double] = []
    var latencyPairsTruth: [Double] = []
    /// Per-subject kappa, excluding any subject whose scored night carries only one class (kappa is
    /// undefined there, and letting a NaN into the mean would quietly void the whole column).
    var subjectKappa: [Double] = []
    var noRemNights = 0
}

func summarise(_ rows: [Scored]) -> Summary {
    var s = Summary()
    var predAcc = [String: Double](), truthAcc = [String: Double]()
    for r in rows {
        var c = Confusion()
        for i in 0..<r.truth.count { c.add(ref: r.truth[i], pred: r.pred[i]) }
        s.conf.merge(c)
        if !c.kappa.isNaN { s.subjectKappa.append(c.kappa) }
        let pp = stagePercentages(r.pred), tp = stagePercentages(r.truth)
        for k in stageOrder { predAcc[k, default: 0] += pp[k]!; truthAcc[k, default: 0] += tp[k]! }
        // Latency: both on the FULL 30 s grid, so both are wall-clock minutes from that night's own
        // sleep onset. The truth column skips unscored epochs when looking for onset and for REM but
        // still counts their slots — collapsing them first would shorten only the truth latency, by
        // however much of the night the technician left unscored.
        let lp = firstRemLatencyMinutes(r.fullPred)
        let lt = firstRemLatencyMinutes(r.fullTruth)
        if let v = lp { s.latencyPred.append(v) } else { s.noRemNights += 1 }
        if let v = lt { s.latencyTruth.append(v) }
        if let x = lp, let y = lt { s.latencyPairsPred.append(x); s.latencyPairsTruth.append(y) }
    }
    let n = Double(rows.count)
    for k in stageOrder { s.predPct[k] = predAcc[k]! / n; s.truthPct[k] = truthAcc[k]! / n }
    return s
}

/// Stage fractions computed over POOLED epochs rather than as a mean of per-night percentages. Both are
/// reported: the pooled number is what a cohort-level "% of night" means, the per-subject mean is what a
/// clinician comparing individuals would use, and they differ whenever night lengths differ.
func pooledPct(_ rows: [Scored], _ pick: (Scored) -> [String]) -> [String: Double] {
    var all: [String] = []
    for r in rows { all.append(contentsOf: pick(r)) }
    return stagePercentages(all)
}

let sh = summarise(shipped)
let pooledPred = pooledPct(shipped) { $0.pred }
let pooledTruth = pooledPct(shipped) { $0.truth }

if want("baseline") {
    print("""

    ================================================================================
    3. SHIPPED SleepStagerV2 vs PSG TRUTH
    ================================================================================
    Four-class agreement over every PSG-scored epoch. `SleepStagerV2` fits no parameters to data — every
    coefficient is fixed a priori — so there is no train/test split to make here: the recipe sees each
    subject exactly once and has never seen any of them. The leave-one-subject-out machinery in section 6
    exists for the fitted comparison models, which do need it.

    epochs scored     \(sh.conf.total)
    accuracy          \(f(sh.accuracy * 100, 6, 2)) %
    Cohen's kappa     \(f(sh.kappa, 6, 3))   (per-subject mean \(f(mean(sh.subjectKappa), 6, 3)) ± \(f(sd(sh.subjectKappa), 5, 3)))

    per stage             precision   recall       F1   support
    """)
    for st in stageOrder {
        let p = sh.conf.prf(st)
        print("      \(st.padding(toLength: 18, withPad: " ", startingAt: 0))\(f(p.precision, 8, 3)) \(f(p.recall, 8, 3)) \(f(p.f1, 8, 3))   \(p.support)")
    }
    print("""

    STAGE FRACTIONS — reported as a first-class result, not an appendix.
    Kappa does not constrain them: PR #348 raised kappa on all three of its benchmarks and was reverted
    48 h later for re-scoring a healthy night from 6 % to 23 % awake.

    stage        predicted %   truth %      bias pp   (pooled over all scored epochs)
    """)
    for st in stageOrder {
        print("      \(st.padding(toLength: 10, withPad: " ", startingAt: 0))\(f(pooledPred[st]!, 10, 2))\(f(pooledTruth[st]!, 10, 2))\(f(pooledPred[st]! - pooledTruth[st]!, 12, 2))")
    }
    print("\n    stage        predicted %   truth %      bias pp   (mean of per-subject percentages)")
    for st in stageOrder {
        print("      \(st.padding(toLength: 10, withPad: " ", startingAt: 0))\(f(sh.predPct[st]!, 10, 2))\(f(sh.truthPct[st]!, 10, 2))\(f(sh.predPct[st]! - sh.truthPct[st]!, 12, 2))")
    }
    print("""

    FIRST-REM LATENCY — minutes from staged sleep onset to the first REM epoch.
    nights with no REM in the prediction: \(sh.noRemNights) of \(shipped.count)

                        predicted     truth
      median          \(f(median(sh.latencyPred), 10, 1))\(f(median(sh.latencyTruth), 10, 1))  min
      mean            \(f(mean(sh.latencyPred), 10, 1))\(f(mean(sh.latencyTruth), 10, 1))  min
      MAE (paired)    \(f(mae(zip(sh.latencyPairsPred, sh.latencyPairsTruth).map { $0 - $1 }), 10, 1))            min  (n = \(sh.latencyPairsPred.count))
    """)

    if !isDreamt {
        // A harness that replaces a deleted one has to say whether it is the same instrument. These are the
        // figures the previous harness reported on this dataset. They are printed as a self-check, NOT as a
        // target: nothing in this tool is tuned to hit them, and where they disagree the disagreement is the
        // finding. See `Variants.preNine30Guard` for what explains the prediction-side gap.
        let ref: [(String, Double, Double, Int)] = [
            ("subjects", Double(subjects.count), 31, 0),
            ("PSG-scored epochs", Double(sh.conf.total), 26773, 0),
            ("kappa (4-class)", sh.kappa, 0.349, 3),
            ("REM F1", sh.conf.prf("rem").f1, 0.515, 3),
            ("REM % of night", sh.predPct["rem"]!, 20.8, 2),
            ("deep % predicted", sh.predPct["deep"]!, 19.25, 2),
            ("deep % truth", sh.truthPct["deep"]!, 14.76, 2),
            ("first-REM predicted, min", median(sh.latencyPred), 142.0, 1),
            ("first-REM truth, min", median(sh.latencyTruth), 88.5, 1),
        ]
        print("""

        SELF-CHECK against the previous harness's reported figures
        Printed to expose disagreement, not to be matched. Nothing here is tuned to these numbers. Stage
        fractions use the per-subject-mean convention, which is the one those figures were reported on.

        quantity                        measured   previously      delta
        """)
        for (name, got, want, dp) in ref {
            print("      \(name.padding(toLength: 28, withPad: " ", startingAt: 0))\(f(got, 9, dp))\(f(want, 13, dp))\(f(got - want, 11, dp))")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Night-length stratification
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("strata") {
    print("""

    ================================================================================
    4. STRATIFIED BY NIGHT LENGTH
    ================================================================================
    Pooling hides a coupling. On one wearer's own nights, `SleepStagerV2` emits more REM as a fraction of
    sleep the longer the night runs — corr(total sleep, REM %) = +0.579 — traced to the REM-latency guard
    being a fixed 60-minute penalty, which therefore covers a third of a short night and a tenth of a long
    one. Whether that reproduces against PSG is a question a pooled table cannot be asked.

    Subjects split into terciles by SCORED night length.
    """)
    let sortedRows = shipped.sorted { $0.subject.scoredMinutes < $1.subject.scoredMinutes }
    let third = max(1, sortedRows.count / 3)
    let strata: [(String, [Scored])] = [
        ("short", Array(sortedRows.prefix(third))),
        ("mid", Array(sortedRows.dropFirst(third).dropLast(sortedRows.count - 2 * third))),
        ("long", Array(sortedRows.suffix(sortedRows.count - 2 * third))),
    ]
    print("    stratum   n   night min      kappa   REM% pred  REM% truth   deep% pred deep% truth  wake% pred wake% truth")
    for (name, rows) in strata where !rows.isEmpty {
        let p = pooledPct(rows) { $0.pred }, t = pooledPct(rows) { $0.truth }
        var c = Confusion()
        for r in rows { for i in 0..<r.truth.count { c.add(ref: r.truth[i], pred: r.pred[i]) } }
        let mins = rows.map { $0.subject.scoredMinutes }
        print("    \(name.padding(toLength: 9, withPad: " ", startingAt: 0))\(rows.count)  \(f(median(mins), 8, 1))  \(f(c.kappa, 9, 3))  \(f(p["rem"]!, 9, 2)) \(f(t["rem"]!, 10, 2))  \(f(p["deep"]!, 10, 2)) \(f(t["deep"]!, 10, 2))  \(f(p["wake"]!, 10, 2)) \(f(t["wake"]!, 10, 2))")
    }
    // The coupling itself, per subject: REM as a percentage of SLEEP (not of the window), against the
    // length of the scored night.
    func remPctOfSleep(_ labels: [String]) -> Double? {
        let sleep = labels.filter { $0 != "wake" }.count
        guard sleep > 0 else { return nil }
        return Double(labels.filter { $0 == "rem" }.count) / Double(sleep) * 100
    }
    var lens: [Double] = [], remPred: [Double] = [], remTruth: [Double] = []
    for r in shipped {
        guard let rp = remPctOfSleep(r.pred), let rt = remPctOfSleep(r.truth) else { continue }
        lens.append(r.subject.scoredMinutes); remPred.append(rp); remTruth.append(rt)
    }
    let cp = pearson(lens, remPred), ct = pearson(lens, remTruth)
    print("""

    corr(scored night length, REM % of SLEEP), n = \(cp.n)
      predicted   Pearson \(f(cp.r, 7, 3))   Spearman \(f(spearman(lens, remPred), 7, 3))
      PSG truth   Pearson \(f(ct.r, 7, 3))   Spearman \(f(spearman(lens, remTruth), 7, 3))
    A coupling the truth also carries is physiology; one only the prediction carries is an artefact.
    """)
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// The REM question
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("rem") {
    print("""

    ================================================================================
    5. IS REM DETECTION PHYSIOLOGY, OR IS IT THE CLOCK?
    ================================================================================
    Three models fit on the same epochs, leave-one-SUBJECT-out, scored only on the held-out subject.
    Clock features are the time-of-night fraction and its square; physiology features are the per-night
    z-scored heart rate, HR-variability and movement plus the HR-flatness percentile — the same normalised
    quantities the recipe's own emissions are built from. Decision threshold tuned on the training folds.
    """)
    var rows: [AblationRow] = []
    for s in subjects {
        let (feats, _) = V2Recipe.stageEpochsDetailed(start: s.start, end: s.end, grav: s.grav,
                                                      hr: s.hr, rr: s.rr, resp: [])
        // Per-night normalisation, matching `stageEpochs`.
        func zfun(_ vals: [Double?]) -> (Double?) -> Double {
            let present = vals.compactMap { $0 }
            if present.isEmpty { return { _ in 0.0 } }
            let m = present.reduce(0, +) / Double(present.count)
            let sd0 = (present.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(present.count)).squareRoot()
            let sdv = sd0 == 0 ? 1.0 : sd0
            return { v in v == nil ? 0.0 : (v! - m) / sdv }
        }
        let zhr = zfun(feats.map { $0.hr }), zhv = zfun(feats.map { $0.hrVar })
        let zmv = zfun(feats.map { Optional($0.moveFrac) })
        let fsorted = feats.compactMap { $0.hrFlat11 }.sorted()
        func fpct(_ v: Double?) -> Double {
            guard let v = v, !fsorted.isEmpty else { return 0.5 }
            var lo = 0, hi = fsorted.count
            while lo < hi { let mid = (lo + hi) / 2; if fsorted[mid] <= v { lo = mid + 1 } else { hi = mid } }
            return Double(lo) / Double(fsorted.count)
        }
        for e in feats {
            let idx = (e.start - s.start) / 30
            guard idx >= 0, idx < s.truth.count, let tv = s.truth[idx] else { continue }
            rows.append(AblationRow(
                subject: s.id, isRem: tv == "rem",
                clock: [e.clock, e.clock * e.clock],
                physiology: [zhr(e.hr), zhv(e.hrVar), zmv(e.moveFrac), fpct(e.hrFlat11)]))
        }
    }
    print("    epochs in the comparison: \(rows.count)   REM prevalence \(f(Double(rows.filter { $0.isRem }.count) / Double(max(1, rows.count)) * 100, 5, 1)) %\n")
    let res = Ablation.run(rows)
    print("    model               pooled F1   pooled P   pooled R   mean per-subject F1")
    for r in res {
        print("      \(r.model.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0))\(f(r.pooledF1, 8, 3))  \(f(r.pooledPrecision, 9, 3))  \(f(r.pooledRecall, 9, 3))   \(f(r.meanSubjectF1, 12, 3))")
    }
    if let clock = res.first(where: { $0.model == .clock }),
       let phys = res.first(where: { $0.model == .physiology }),
       let both = res.first(where: { $0.model == .both }) {
        let subs = clock.subjectF1.keys.sorted()
        let dPhys = subs.compactMap { s -> Double? in
            guard let c = clock.subjectF1[s], let p = phys.subjectF1[s] else { return nil }
            return p - c
        }
        let dBoth = subs.compactMap { s -> Double? in
            guard let c = clock.subjectF1[s], let b = both.subjectF1[s] else { return nil }
            return b - c
        }
        print("""

            what physiology adds over the clock, per subject
              physiology-only − clock-only   mean \(f(mean(dPhys), 7, 3))   positive in \(dPhys.filter { $0 > 0 }.count)/\(dPhys.count) subjects
              both − clock-only              mean \(f(mean(dBoth), 7, 3))   positive in \(dBoth.filter { $0 > 0 }.count)/\(dBoth.count) subjects
              pooled: physiology-only − clock-only \(f(phys.pooledF1 - clock.pooledF1, 7, 3)),  both − clock-only \(f(both.pooledF1 - clock.pooledF1, 7, 3))

            For reference, the SHIPPED recipe's own REM F1 on these epochs is \(f(sh.conf.prf("rem").f1, 6, 3)) — it fits
            nothing, so it is not comparable to a fitted model's held-out score and is printed only for scale.
        """)
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Variants
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("variants") {
    print("""

    ================================================================================
    6. RECIPE VARIANTS AGAINST PSG
    ================================================================================
    Every row is the shipped recipe with ONE named change. Deltas are against the incumbent row.
    `wake bias` and `deep bias` are predicted minus truth in percentage points — the #437 guard, which
    kappa does not carry.
    """)
    var csvLines = [(["variant", "epochs", "kappa", "accuracy"]
        + stageOrder.flatMap { ["\($0)_precision", "\($0)_recall", "\($0)_f1", "\($0)_pct", "\($0)_bias_pp"] }
        + ["median_rem_latency_min", "rem_latency_mae_min"]).joined(separator: ",")]
    var base: (kappa: Double, remF1: Double, wakeSens: Double)?
    // Wake SENSITIVITY is in the table beside kappa because it is the quantity #987 was landed on against
    // the strap's band state (16.0 % → 17.6 %). Printing it here is what makes that claim checkable against
    // truth rather than merely restated.
    print("    variant                          kappa     Δκ   REM F1  wakeSens   wake%  bias   deep%  bias    REM%  bias   latMAE")
    for v in Variants.all {
        let rows = v.name.hasPrefix("incumbent")
            ? shipped
            : subjects.map { score($0, using: stageVariant(v.config)) }
        let s = summarise(rows)
        let p = pooledPct(rows) { $0.pred }, t = pooledPct(rows) { $0.truth }
        let latMae = mae(zip(s.latencyPairsPred, s.latencyPairsTruth).map { $0 - $1 })
        let wakeSens = s.conf.prf("wake").recall * 100
        if base == nil { base = (s.kappa, s.conf.prf("rem").f1, wakeSens) }
        let b = base!
        print("    \(v.name.padding(toLength: 32, withPad: " ", startingAt: 0))\(f(s.kappa, 6, 3)) \(f(s.kappa - b.kappa, 6, 3))   \(f(s.conf.prf("rem").f1, 6, 3))  \(f(wakeSens, 6, 2))\(f(wakeSens - b.wakeSens, 6, 2))  \(f(p["wake"]!, 6, 2))\(f(p["wake"]! - t["wake"]!, 6, 2))  \(f(p["deep"]!, 6, 2))\(f(p["deep"]! - t["deep"]!, 6, 2))  \(f(p["rem"]!, 6, 2))\(f(p["rem"]! - t["rem"]!, 6, 2))  \(f(latMae, 6, 1))")
        var row = [v.name, "\(s.conf.total)", "\(s.kappa)", "\(s.accuracy)"]
        for st in stageOrder {
            let m = s.conf.prf(st)
            row += ["\(m.precision)", "\(m.recall)", "\(m.f1)", "\(p[st]!)", "\(p[st]! - t[st]!)"]
        }
        row += ["\(median(s.latencyPred))", "\(latMae)"]
        csvLines.append(row.joined(separator: ","))
    }
    print("""

    A component is an improvement here only if it raises kappa AND does not blow out a stage fraction.
    That conjunction is the lesson of #348 → #437: kappa alone certified a build that mis-called a
    healthy night's wake fraction by 17 percentage points.
    """)
    if let path = a.csv {
        try? csvLines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("    per-variant CSV written to \(path)")
    }
}

if want("priors") {
    print("""

    ================================================================================
    7. BASE PRIORS, SUBJECT BY SUBJECT
    ================================================================================
    The pooled table above can be carried by a few long nights. Here every subject counts once: their own
    kappa, and how far each stage's share of THEIR night is from their own PSG. The deep prior moved 0.18 →
    0.15 on this section's evidence; the "before" row is that change undone, and #348-A adds the awake half
    the recipe does not take. `better` counts subjects whose value improved against the incumbent (kappa up,
    |bias| down); a tie counts as neither.
    """)
    func perSubject(_ rows: [Scored]) -> [(kappa: Double, bias: [String: Double])] {
        rows.map { r in
            let bias = stageBias(ref: r.truth, pred: r.pred)
            return (confusion(ref: r.truth, pred: r.pred).kappa, bias)
        }
    }
    let base = perSubject(shipped)
    print("    variant                     mean κ  better κ   mean|bias| wake  deep   REM  light   better |bias| wake deep  REM light")
    for v in [Variants.incumbent, Variants.deepPriorBefore, Variants.p348Priors] {
        let rows = v.name.hasPrefix("incumbent") ? shipped : subjects.map { score($0, using: stageVariant(v.config)) }
        let ps = perSubject(rows)
        let n = ps.count
        let kBetter = zip(ps, base).filter { $0.0.kappa > $0.1.kappa }.count
        func meanAbs(_ st: String) -> Double { mean(ps.map { abs($0.bias[st] ?? 0) }) }
        func better(_ st: String) -> Int { zip(ps, base).filter { abs($0.0.bias[st] ?? 0) < abs($0.1.bias[st] ?? 0) }.count }
        print("    \(v.name.padding(toLength: 26, withPad: " ", startingAt: 0))\(f(mean(ps.map { $0.kappa }), 7, 3))   \(kBetter)/\(n)     "
              + "\(f(meanAbs("wake"), 5, 2)) \(f(meanAbs("deep"), 5, 2)) \(f(meanAbs("rem"), 5, 2)) \(f(meanAbs("light"), 5, 2))      "
              + "\(better("wake"))/\(n) \(better("deep"))/\(n) \(better("rem"))/\(n) \(better("light"))/\(n)")
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// The RSA term, live against silenced (DREAMT: the only dataset here with beat-to-beat intervals)
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("rsa") && subjects.contains(where: { !$0.rr.isEmpty }) {
    print("""

    ================================================================================
    8. THE RSA TERM — the shipped recipe with R-R, against the same recipe with R-R withheld
    ================================================================================
    The only change between the columns is the R-R stream: `on` is the shipped recipe as the app runs it,
    `off` passes no beats, which silences the RSA respiration term exactly as sleep-accel does. Both are
    `SleepStagerV2.stageSession` itself. REM is the stage the term exists for. Strata: apnoea severity (AHI,
    events/hour) and how many of the beats the E4 kept (coverage over scored sleep). Stage % are pooled over
    all scored epochs of the stratum; REM/sleep is REM as a share of scored SLEEP epochs.
    """)
    let off = subjects.map { s in score(s) { SleepStagerV2.stageSession(start: $0.start, end: $0.end, grav: $0.grav,
                                                                           hr: $0.hr, rr: [], resp: []) } }
    func remOfSleep(_ labels: [String]) -> Double {
        let sleep = labels.filter { $0 != "wake" }.count
        return sleep == 0 ? .nan : 100 * Double(labels.filter { $0 == "rem" }.count) / Double(sleep)
    }
    func line(_ name: String, _ idx: [Int]) {
        guard !idx.isEmpty else { return }
        let on = idx.map { shipped[$0] }, of = idx.map { off[$0] }
        func pooled(_ rows: [Scored]) -> Confusion {
            var c = Confusion(); for r in rows { for i in 0..<r.truth.count { c.add(ref: r.truth[i], pred: r.pred[i]) } }; return c
        }
        let cOn = pooled(on), cOf = pooled(of)
        let pOn = pooledPct(on) { $0.pred }, pOf = pooledPct(of) { $0.pred }, pT = pooledPct(on) { $0.truth }
        let rsOn = remOfSleep(on.flatMap { $0.pred }), rsOf = remOfSleep(of.flatMap { $0.pred })
        let rsT = remOfSleep(on.flatMap { $0.truth })
        let kOn = on.map { confusion(ref: $0.truth, pred: $0.pred).kappa }
        let kOf = of.map { confusion(ref: $0.truth, pred: $0.pred).kappa }
        let kUp = zip(kOn, kOf).filter { $0.0 > $0.1 }.count, kDown = zip(kOn, kOf).filter { $0.0 < $0.1 }.count
        let remOn = cOn.prf("rem"), remOf = cOf.prf("rem")
        print("    \(name.padding(toLength: 14, withPad: " ", startingAt: 0))\(String(idx.count).padding(toLength: 4, withPad: " ", startingAt: 0))"
              + "κ \(f(cOf.kappa, 5, 3))→\(f(cOn.kappa, 5, 3))  up/down \(kUp)/\(kDown)  "
              + "REM P \(f(remOf.precision, 4, 2))→\(f(remOn.precision, 4, 2)) R \(f(remOf.recall, 4, 2))→\(f(remOn.recall, 4, 2)) "
              + "F1 \(f(remOf.f1, 4, 2))→\(f(remOn.f1, 4, 2))  "
              + "REM% \(f(pOf["rem"]!, 5, 1))→\(f(pOn["rem"]!, 5, 1)) (\(f(pT["rem"]!, 5, 1)))  "
              + "REM/sleep \(f(rsOf, 5, 1))→\(f(rsOn, 5, 1)) (\(f(rsT, 5, 1)))  "
              + "wake% \(f(pOf["wake"]!, 5, 1))→\(f(pOn["wake"]!, 5, 1)) (\(f(pT["wake"]!, 5, 1)))  "
              + "deep% \(f(pOf["deep"]!, 5, 1))→\(f(pOn["deep"]!, 5, 1)) (\(f(pT["deep"]!, 5, 1)))")
    }
    print("    stratum       n   κ off→on       per-subject κ   REM precision / recall / F1, off→on          "
          + "REM % of night (truth)   REM % of sleep (truth)   wake %, deep % (truth)")
    let all = Array(subjects.indices)
    line("all", all)
    let ahi: (Int) -> Double? = { subjects[$0].ahi }
    line("AHI <5", all.filter { (ahi($0) ?? -1) >= 0 && ahi($0)! < 5 })
    line("AHI 5–15", all.filter { (ahi($0) ?? -1) >= 5 && ahi($0)! < 15 })
    line("AHI 15–30", all.filter { (ahi($0) ?? -1) >= 15 && ahi($0)! < 30 })
    line("AHI ≥30", all.filter { (ahi($0) ?? -1) >= 30 })
    let cov = subjects.map { beatCoverage($0) }
    line("beats <50%", all.filter { cov[$0] < 0.5 })
    line("beats 50–80%", all.filter { cov[$0] >= 0.5 && cov[$0] < 0.8 })
    line("beats ≥80%", all.filter { cov[$0] >= 0.8 })
    line("≥80%, AHI <15", all.filter { cov[$0] >= 0.8 && (ahi($0) ?? 99) < 15 })

    // Does the feature carry the physiology the term assumes? The recipe adds respWeight·z to DEEP and
    // subtracts it from REM (regular breathing → deep, irregular → REM) and leaves light alone. z is the
    // per-night z-score of the RSA peakedness, exactly as `stageEpochs` computes it. If z does not separate
    // the truth stages, a symmetric ±z on deep and REM only moves epochs OUT of light, into both.
    print("""

    Is the feature informative? Per-night z of the RSA peakedness, grouped by the PSG stage of the epoch.
    AUC = P(z of a random epoch of the first stage > z of a random REM epoch); 0.5 = no information, and the
    recipe's sign assumes AUC > 0.5 for deep vs REM. `present` = epochs where the feature is not nil.
    """)
    var zBy = [String: [Double]](), presentBy = [String: (Int, Int)]()
    var subjAUC: [Double] = []
    for s in subjects {
        let (feats, _) = V2Recipe.stageEpochsDetailed(start: s.start, end: s.end, grav: s.grav, hr: s.hr, rr: s.rr, resp: [])
        let vals = feats.map { $0.respReg }
        let present = vals.compactMap { $0 }
        guard present.count >= 2 else { continue }
        let m = present.reduce(0, +) / Double(present.count)
        let sd0 = (present.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(present.count)).squareRoot()
        let sdv = sd0 == 0 ? 1.0 : sd0
        var nrem: [Double] = [], rem: [Double] = []
        for (i, st) in s.truth.enumerated() where i < feats.count {
            guard let st = st else { continue }
            var pc = presentBy[st] ?? (0, 0); pc.1 += 1
            if let v = vals[i] {
                pc.0 += 1
                let z = (v - m) / sdv
                zBy[st, default: []].append(z)
                if st == "rem" { rem.append(z) } else if st != "wake" { nrem.append(z) }
            }
            presentBy[st] = pc
        }
        if nrem.count >= 20 && rem.count >= 20 { subjAUC.append(aucGreater(nrem, rem)) }
    }
    for st in stageOrder {
        let z = zBy[st] ?? [], pc = presentBy[st] ?? (0, 0)
        print("      \(st.padding(toLength: 7, withPad: " ", startingAt: 0)) mean z \(f(mean(z), 6, 3))   median z \(f(median(z), 6, 3))   present \(f(pc.1 == 0 ? .nan : 100 * Double(pc.0) / Double(pc.1), 5, 1)) %")
    }
    let zr = zBy["rem"] ?? []
    print("""
          AUC deep vs REM   \(f(aucGreater(zBy["deep"] ?? [], zr), 6, 3))   light vs REM \(f(aucGreater(zBy["light"] ?? [], zr), 6, 3))   \
    wake vs REM \(f(aucGreater(zBy["wake"] ?? [], zr), 6, 3))   (pooled epochs)
          per-subject AUC NREM vs REM: median \(f(median(subjAUC), 6, 3)), > 0.5 in \(subjAUC.filter { $0 > 0.5 }.count)/\(subjAUC.count) subjects
    """)

    // Shapes of the term, subject by subject (every subject counts once, as in section 7).
    print("""

    Shapes of the term, subject by subject. `better κ` counts subjects whose own kappa rises against the
    shipped recipe; |bias| is each subject's |predicted − truth| share of their night, averaged.
    """)
    func shapeRows(_ name: String, _ idx: [Int]) {
        let base = idx.map { shipped[$0] }
        let baseK = base.map { confusion(ref: $0.truth, pred: $0.pred).kappa }
        print("    \(name)   (n = \(idx.count))")
        print("      shape                 w     mean κ  better/worse κ   mean|bias| wake  deep   REM  light   REM/sleep (truth)")
        let w0 = RecipeConfig.shipped.respWeight
        let shapes: [(String, RecipeConfig.RespShape, Double)] = [0.6, 0.45, 0.3, 0.2].map { w in
            (w == w0 ? "symmetric (shipped)" : "symmetric", RecipeConfig.RespShape.symmetric, w)
        } + [
            ("off", .symmetric, 0.0),
            ("regularOnly", .regularOnly, 0.6), ("regularOnly", .regularOnly, 1.2), ("remOnly", .remOnly, 0.6),
        ]
        for (label, shape, w) in shapes {
            var cfg = RecipeConfig.shipped; cfg.respShape = shape; cfg.respWeight = w
            let rows = idx.map { score(subjects[$0], using: stageVariant(cfg)) }
            let k = rows.map { confusion(ref: $0.truth, pred: $0.pred).kappa }
            let up = zip(k, baseK).filter { $0.0 > $0.1 + 1e-12 }.count, dn = zip(k, baseK).filter { $0.0 < $0.1 - 1e-12 }.count
            let biases = rows.map { stageBias(ref: $0.truth, pred: $0.pred) }
            func mb(_ st: String) -> Double { mean(biases.map { abs($0[st] ?? 0) }) }
            print("      \(label.padding(toLength: 20, withPad: " ", startingAt: 0))\(f(w, 4, 2))  \(f(mean(k), 7, 3))   \(String(up).padding(toLength: 3, withPad: " ", startingAt: 0))/ \(String(dn).padding(toLength: 3, withPad: " ", startingAt: 0))         "
                  + "\(f(mb("wake"), 5, 2)) \(f(mb("deep"), 5, 2)) \(f(mb("rem"), 5, 2)) \(f(mb("light"), 5, 2))   "
                  + "\(f(remOfSleep(rows.flatMap { $0.pred }), 5, 1)) (\(f(remOfSleep(rows.flatMap { $0.truth }), 4, 1)))")
        }
    }
    shapeRows("all", all)
    shapeRows("AHI <5", all.filter { (ahi($0) ?? -1) >= 0 && ahi($0)! < 5 })
    shapeRows("beats ≥80%", all.filter { cov[$0] >= 0.8 })

    // The dose: the shipped weight, half of it, and none (= R-R withheld, since a nil feature scores z = 0).
    print("\n    respWeight dose (port; shipped: \(f(RecipeConfig.shipped.respWeight, 4, 2)))")
    for w in [0.6, 0.3, 0.0] {
        var cfg = RecipeConfig.shipped; cfg.respWeight = w
        let rows = subjects.map { score($0, using: stageVariant(cfg)) }
        var c = Confusion(); for r in rows { for i in 0..<r.truth.count { c.add(ref: r.truth[i], pred: r.pred[i]) } }
        let p = pooledPct(rows) { $0.pred }
        print("      \(f(w, 4, 2))   κ \(f(c.kappa, 6, 3))   REM F1 \(f(c.prf("rem").f1, 5, 3))   deep F1 \(f(c.prf("deep").f1, 5, 3))   "
              + "REM/sleep \(f(remOfSleep(rows.flatMap { $0.pred }), 5, 1))   REM% \(f(p["rem"]!, 5, 1))   deep% \(f(p["deep"]!, 5, 1))   light% \(f(p["light"]!, 5, 1))")
    }
}

print("")
