import Foundation
import StrandAnalytics

// Scoring — the agreement and calibration primitives, over plain label arrays.
//
// The definitions here match `Tools/SleepBench/Sources/sleepbench/Metrics.swift` deliberately: the two
// harnesses score the same recipe against different references, and a kappa that meant something slightly
// different in each would make their numbers incomparable exactly when someone needs to compare them.
// `ScoringTests` pins the shared ones against hand-computed values so a divergence is caught rather than
// discovered.
//
// The one primitive SleepBench does not carry is per-stage F1. It belongs here because the question this
// dataset exists to answer is about REM specifically, and REM is a minority class: on a night that is 20 %
// REM, a recipe that emits no REM at all still scores 80 % accuracy and a respectable four-class kappa.
// Precision and recall for that one class, and their harmonic mean, are what move when REM detection does.

let stageOrder = ["wake", "light", "deep", "rem"]
let epochSeconds = 30.0

func epochCount(start: Int, end: Int) -> Int {
    max(1, Int(ceil(Double(end - start) / epochSeconds)))
}

/// Expand a `[StageSegment]` tiling into a per-epoch label array on the 30 s grid, taking each epoch's
/// label from the segment covering its START instant — the same convention `SleepBench` uses.
func epochLabels(_ stages: [StageSegment], start: Int, end: Int) -> [String] {
    let n = epochCount(start: start, end: end)
    var out = [String](repeating: "wake", count: n)
    guard !stages.isEmpty else { return out }
    let sorted = stages.sorted { $0.start < $1.start }
    var si = 0
    for i in 0..<n {
        let t = start + Int(Double(i) * epochSeconds)
        while si + 1 < sorted.count && sorted[si].end <= t { si += 1 }
        let seg = sorted[si]
        if seg.start <= t && t < seg.end { out[i] = seg.stage }
        else if let hit = sorted.first(where: { $0.start <= t && t < $0.end }) { out[i] = hit.stage }
        else if t >= sorted[sorted.count - 1].end { out[i] = sorted[sorted.count - 1].stage }
    }
    return out
}

// MARK: - Stage-fraction calibration

/// Each stage's share of the epochs, as a percentage.
///
/// This is the quantity Cohen's kappa does NOT constrain, and the reason it is reported beside kappa
/// everywhere in this tool rather than in an appendix. PR #348 raised kappa on all three of its benchmarks
/// and was reverted 48 h later for re-scoring a healthy night from 6 % to 23 % awake: a recipe can win more
/// epochs than it loses while systematically shifting how much of the night it spends in a stage. Every
/// stage in `stageOrder` is present at 0 when unused, so a stage a recipe stops emitting shows up as a bias
/// rather than as a missing row.
func stagePercentages(_ labels: [String]) -> [String: Double] {
    var pct = [String: Double](uniqueKeysWithValues: stageOrder.map { ($0, 0.0) })
    guard !labels.isEmpty else { return pct }
    for l in labels { pct[l, default: 0] += 1 }
    for k in pct.keys { pct[k]! = pct[k]! / Double(labels.count) * 100 }
    return pct
}

/// Signed per-stage calibration error in percentage points, `predicted% − reference%`.
func stageBias(ref: [String], pred: [String]) -> [String: Double] {
    let r = stagePercentages(ref), p = stagePercentages(pred)
    return [String: Double](uniqueKeysWithValues: stageOrder.map { ($0, p[$0]! - r[$0]!) })
}

/// Minutes from sleep onset (first non-wake epoch) to the first REM epoch. `nil` when the hypnogram has no
/// sleep or never reaches REM — a night with no REM is a distinct outcome from one whose REM arrives at
/// minute zero, and collapsing them would let a recipe that stops emitting REM look fast.
func firstRemLatencyMinutes(_ labels: [String]) -> Double? {
    guard let onset = labels.firstIndex(where: { $0 != "wake" }),
          let rem = labels.firstIndex(of: "rem"), rem >= onset else { return nil }
    return Double(rem - onset) * epochSeconds / 60.0
}

/// The same latency over a grid with unscored epochs in it. The nils are skipped when looking for onset
/// and for REM, but they still occupy their slot in the index arithmetic — so the answer stays wall-clock
/// minutes. Collapsing the array first and counting the survivors would shorten the latency by however
/// much of the night the PSG technician left unscored, silently and only for the truth column.
func firstRemLatencyMinutes(_ labels: [String?]) -> Double? {
    guard let onset = labels.firstIndex(where: { $0 != nil && $0 != "wake" }),
          let rem = labels.firstIndex(where: { $0 == "rem" }), rem >= onset else { return nil }
    return Double(rem - onset) * epochSeconds / 60.0
}

// MARK: - Agreement

/// A square confusion matrix over `classes`, rows = reference, cols = prediction.
struct Confusion {
    let classes: [String]
    var m: [[Int]]
    init(classes: [String] = stageOrder) {
        self.classes = classes
        m = Array(repeating: Array(repeating: 0, count: classes.count), count: classes.count)
    }
    mutating func add(ref: String, pred: String) {
        guard let r = classes.firstIndex(of: ref), let c = classes.firstIndex(of: pred) else { return }
        m[r][c] += 1
    }
    mutating func merge(_ o: Confusion) {
        for i in 0..<m.count { for j in 0..<m.count { m[i][j] += o.m[i][j] } }
    }
    var total: Int { m.flatMap { $0 }.reduce(0, +) }
    var accuracy: Double {
        let t = total
        return t == 0 ? 0 : Double((0..<m.count).reduce(0) { $0 + m[$1][$1] }) / Double(t)
    }
    /// Cohen's kappa: (p_o − p_e) / (1 − p_e).
    var kappa: Double {
        let t = Double(total)
        guard t > 0 else { return .nan }
        let po = accuracy
        var pe = 0.0
        for i in 0..<m.count {
            let rowSum = Double(m[i].reduce(0, +))
            let colSum = Double((0..<m.count).reduce(0) { $0 + m[$1][i] })
            pe += (rowSum / t) * (colSum / t)
        }
        return pe >= 1.0 ? .nan : (po - pe) / (1 - pe)
    }
    /// One-vs-rest precision, recall and F1 for `cls`. `support` is the reference count, so a class the
    /// recipe never emits is distinguishable from a class the reference never contains.
    func prf(_ cls: String) -> (precision: Double, recall: Double, f1: Double, support: Int) {
        guard let k = classes.firstIndex(of: cls) else { return (.nan, .nan, .nan, 0) }
        var tp = 0, fn = 0, fp = 0
        for i in 0..<m.count {
            for j in 0..<m.count {
                let v = m[i][j]
                if i == k && j == k { tp += v } else if i == k { fn += v } else if j == k { fp += v }
            }
        }
        let prec = (tp + fp) == 0 ? Double.nan : Double(tp) / Double(tp + fp)
        let rec = (tp + fn) == 0 ? Double.nan : Double(tp) / Double(tp + fn)
        let f1: Double = (prec.isNaN || rec.isNaN || prec + rec == 0) ? 0 : 2 * prec * rec / (prec + rec)
        return (prec, rec, f1, tp + fn)
    }
    /// One-vs-rest sensitivity/specificity, kept for parity with SleepBench's wake-sensitivity reporting.
    func sensSpec(_ cls: String) -> (sens: Double, spec: Double, n: Int) {
        guard let k = classes.firstIndex(of: cls) else { return (.nan, .nan, 0) }
        var tp = 0, fn = 0, fp = 0, tn = 0
        for i in 0..<m.count {
            for j in 0..<m.count {
                let v = m[i][j]
                if i == k && j == k { tp += v } else if i == k { fn += v }
                else if j == k { fp += v } else { tn += v }
            }
        }
        let sens = (tp + fn) == 0 ? Double.nan : Double(tp) / Double(tp + fn)
        let spec = (tn + fp) == 0 ? Double.nan : Double(tn) / Double(tn + fp)
        return (sens, spec, tp + fn)
    }
}

func confusion(ref: [String], pred: [String], classes: [String] = stageOrder) -> Confusion {
    var c = Confusion(classes: classes)
    for i in 0..<min(ref.count, pred.count) { c.add(ref: ref[i], pred: pred[i]) }
    return c
}

/// Collapse a 4-class hypnogram to the 2-class sleep/wake problem.
func toSleepWake(_ labels: [String]) -> [String] { labels.map { $0 == "wake" ? "wake" : "sleep" } }

/// Binary F1 for a single positive class, over aligned label arrays. The REM ablation's headline number.
func binaryF1(ref: [Bool], pred: [Bool]) -> Double {
    var tp = 0, fp = 0, fn = 0
    for i in 0..<min(ref.count, pred.count) {
        if ref[i] && pred[i] { tp += 1 } else if !ref[i] && pred[i] { fp += 1 } else if ref[i] && !pred[i] { fn += 1 }
    }
    if tp == 0 { return 0 }
    let prec = Double(tp) / Double(tp + fp)
    let rec = Double(tp) / Double(tp + fn)
    return 2 * prec * rec / (prec + rec)
}

// MARK: - Descriptive statistics

func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }
func median(_ v: [Double]) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}
func sd(_ v: [Double]) -> Double {
    guard v.count > 1 else { return .nan }
    let m = mean(v)
    return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)).squareRoot()
}
func mae(_ v: [Double]) -> Double { mean(v.map { abs($0) }) }

/// Pearson correlation and its two-sided t statistic.
func pearson(_ x: [Double], _ y: [Double]) -> (r: Double, n: Int, t: Double) {
    let n = min(x.count, y.count)
    guard n > 2 else { return (.nan, n, .nan) }
    let mx = mean(Array(x.prefix(n))), my = mean(Array(y.prefix(n)))
    var sxy = 0.0, sxx = 0.0, syy = 0.0
    for i in 0..<n {
        let dx = x[i] - mx, dy = y[i] - my
        sxy += dx * dy; sxx += dx * dx; syy += dy * dy
    }
    guard sxx > 0, syy > 0 else { return (.nan, n, .nan) }
    let r = sxy / (sxx * syy).squareRoot()
    let t = r * (Double(n - 2) / max(1e-12, 1 - r * r)).squareRoot()
    return (r, n, t)
}

/// Spearman rank correlation — reported beside Pearson because a monotone-but-curved coupling (which is
/// what a saturating penalty produces) shows up in the ranks before it shows up in the linear fit.
func spearman(_ x: [Double], _ y: [Double]) -> Double {
    let n = min(x.count, y.count)
    guard n > 2 else { return .nan }
    func ranks(_ v: [Double]) -> [Double] {
        let idx = v.indices.sorted { v[$0] < v[$1] }
        var r = [Double](repeating: 0, count: v.count)
        var i = 0
        while i < idx.count {
            var j = i
            while j + 1 < idx.count && v[idx[j + 1]] == v[idx[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for k in i...j { r[idx[k]] = avg }
            i = j + 1
        }
        return r
    }
    return pearson(ranks(Array(x.prefix(n))), ranks(Array(y.prefix(n)))).r
}

func f(_ v: Double, _ w: Int = 7, _ p: Int = 1) -> String {
    v.isNaN ? String(repeating: " ", count: max(0, w - 3)) + "n/a" : String(format: "%\(w).\(p)f", v)
}
