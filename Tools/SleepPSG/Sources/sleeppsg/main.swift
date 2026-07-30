import Foundation
import StrandAnalytics
import WhoopProtocol

// sleeppsg — score NOOP's shipped sleep stager against polysomnography.
//
// USAGE:  sleeppsg --dataset /path/to/sleep-accel-1.0.0 [--section all] [--csv out.csv] [--subjects N]
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
        usage: sleeppsg --dataset <sleep-accel root> [--section all|port|baseline|strata|rem|variants]
                        [--subjects N] [--csv <path>] [--seed <n>]

          --dataset   PhysioNet sleep-accel v1.0.0, extracted. See README.md for the download step and the
                      attribution its licence requires. Never committed; read-only here.
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
guard let root = SleepAccel.resolveRoot(datasetArg) else {
    FileHandle.standardError.write(Data("no `labels/` directory under \(datasetArg) — is that the sleep-accel root?\n".utf8))
    exit(2)
}

var ids = SleepAccel.subjectIDs(root: root)
if let n = a.subjects { ids = Array(ids.prefix(n)) }
// Loaded concurrently — the motion files run to tens of megabytes of text each and the read dominates the
// whole run. Order is restored from `ids` afterwards so the report is identical however the threads finish.
var loaded = [PSGSubject?](repeating: nil, count: ids.count)
loaded.withUnsafeMutableBufferPointer { buf in
    let out = buf
    DispatchQueue.concurrentPerform(iterations: ids.count) { i in
        out[i] = SleepAccel.load(root: root, id: ids[i])
    }
}
let subjects: [PSGSubject] = loaded.compactMap { $0 }
guard !subjects.isEmpty else {
    FileHandle.standardError.write(Data("no scorable subjects under \(root)\n".utf8)); exit(1)
}

let totalScored = subjects.reduce(0) { $0 + $1.scoredEpochs }
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
    SleepStagerV2.stageSession(start: s.start, end: s.end, grav: s.grav, hr: s.hr, rr: [], resp: [])
}
func stageVariant(_ cfg: RecipeConfig) -> (PSGSubject) -> [StageSegment] {
    { s in V2Recipe.stageSession(start: s.start, end: s.end, grav: s.grav, hr: s.hr,
                                 rr: [], resp: [], cfg: cfg) }
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
                                                      hr: s.hr, rr: [], resp: [])
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

print("")
