import Foundation
import StrandAnalytics

/// The four scored classes, in a fixed order so every confusion matrix in the run is indexed alike.
let stageOrder = ["wake", "light", "deep", "rem"]

/// 30 s epochs, matching `SleepStager.epochS` and the grid `stagesJSON` / `sleepStateJSON` are stored on.
let epochSeconds = 30.0

func epochCount(start: Int, end: Int) -> Int {
    max(1, Int(ceil(Double(end - start) / epochSeconds)))
}

/// Expand a `[StageSegment]` tiling into a per-epoch label array on the 30 s grid, taking each epoch's
/// label from the segment covering its START instant — the same convention `applyBandStateWakeVeto` uses,
/// so an expand→collapse round-trip is exact.
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

/// Minutes at each stage in a label array.
func stageMinutes(_ labels: [String]) -> [String: Double] {
    var m: [String: Double] = [:]
    for l in labels { m[l, default: 0] += epochSeconds / 60.0 }
    return m
}

func wakeMinutes(_ labels: [String]) -> Double { stageMinutes(labels)["wake"] ?? 0 }
func sleepMinutes(_ labels: [String]) -> Double {
    Double(labels.filter { $0 != "wake" }.count) * epochSeconds / 60.0
}

/// Index of the first and last non-wake epoch — sleep onset and final wake on this grid.
func onsetAndFinalWake(_ labels: [String]) -> (onset: Int?, final: Int?) {
    (labels.firstIndex(where: { $0 != "wake" }), labels.lastIndex(where: { $0 != "wake" }))
}

// MARK: - Stage-fraction calibration

/// Each stage's share of the night, as a percentage of the session's epochs.
///
/// This is the quantity Cohen's kappa does NOT constrain. Kappa scores whether the predicted label at an
/// epoch matches the reference label at that epoch; a recipe can raise kappa while systematically shifting
/// how much of the night it calls wake, because the epochs it newly gets right can outnumber the epochs it
/// newly mislabels. PR #348 did exactly that (kappa up on all three benchmarks, held-out gap −0.027) and
/// PR #437 reverted it two days later for re-scoring a healthy night from 6% to 23% awake. Every stage in
/// `stageOrder` is present in the result, at 0 when the hypnogram never uses it, so a stage a recipe stops
/// emitting altogether shows up as a bias rather than as a missing row.
func stagePercentages(_ labels: [String]) -> [String: Double] {
    var pct = [String: Double](uniqueKeysWithValues: stageOrder.map { ($0, 0.0) })
    guard !labels.isEmpty else { return pct }
    for l in labels { pct[l, default: 0] += 1 }
    for k in pct.keys { pct[k]! = pct[k]! / Double(labels.count) * 100 }
    return pct
}

/// Signed per-stage calibration error in percentage points, `predicted% − reference%`.
/// Positive means the recipe spends MORE of the night at that stage than the human did.
func stageBias(ref: [String], pred: [String]) -> [String: Double] {
    let r = stagePercentages(ref), p = stagePercentages(pred)
    return [String: Double](uniqueKeysWithValues: stageOrder.map { ($0, p[$0]! - r[$0]!) })
}

/// Minutes from staged sleep onset (the first non-wake epoch) to the first REM epoch.
///
/// `nil` when the hypnogram has no sleep at all or never reaches REM — a night with no REM is a distinct
/// outcome from a night whose REM arrives at minute zero, and collapsing the two would let a recipe that
/// stops emitting REM look like one with a short latency. Callers report the `nil` count separately.
/// REM before onset cannot occur (REM is not wake, so onset is at or before it), but the guard is kept so
/// a caller passing a hand-built label array cannot produce a negative latency.
func firstRemLatencyMinutes(_ labels: [String]) -> Double? {
    guard let onset = labels.firstIndex(where: { $0 != "wake" }),
          let rem = labels.firstIndex(of: "rem"), rem >= onset else { return nil }
    return Double(rem - onset) * epochSeconds / 60.0
}

// MARK: - Agreement

/// A square confusion matrix over `classes`, rows = reference, cols = prediction.
struct Confusion {
    let classes: [String]
    var m: [[Int]]
    init(classes: [String]) {
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
    /// Cohen's kappa: (p_o - p_e) / (1 - p_e).
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
    /// One-vs-rest sensitivity (recall) and specificity for `cls`.
    func sensSpec(_ cls: String) -> (sens: Double, spec: Double, n: Int) {
        guard let k = classes.firstIndex(of: cls) else { return (.nan, .nan, 0) }
        var tp = 0, fn = 0, fp = 0, tn = 0
        for i in 0..<m.count {
            for j in 0..<m.count {
                let v = m[i][j]
                if i == k && j == k { tp += v }
                else if i == k { fn += v }
                else if j == k { fp += v }
                else { tn += v }
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

/// Collapse a 4-class hypnogram to the 2-class sleep/wake problem the wake over-call lives in.
func toSleepWake(_ labels: [String]) -> [String] { labels.map { $0 == "wake" ? "wake" : "sleep" } }

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
/// Nearest-rank percentile, `p` in 0...1. Used for the p10/p90 spread of a stage-fraction or latency
/// distribution, where a mean alone hides the tail a regression shows up in first.
func percentile(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted()
    let i = Int((Double(s.count) - 1) * p + 0.5)
    return s[min(s.count - 1, max(0, i))]
}
/// Mean absolute value — the unsigned companion to a signed bias, so a recipe that is unbiased on average
/// because it over- and under-calls in equal measure cannot pass as well calibrated.
func mae(_ v: [Double]) -> Double { mean(v.map { abs($0) }) }
/// Pearson correlation, plus the two-sided t statistic that goes with it.
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

func f(_ v: Double, _ w: Int = 7, _ p: Int = 1) -> String {
    v.isNaN ? String(repeating: " ", count: w - 3) + "n/a"
        : String(format: "%\(w).\(p)f", v)
}
