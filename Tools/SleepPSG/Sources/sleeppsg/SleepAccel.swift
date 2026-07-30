import Foundation
import WhoopProtocol

// SleepAccel — read PhysioNet `sleep-accel` v1.0.0 and present each subject as the streams a NOOP stager
// takes, plus the PSG hypnogram to score against.
//
//   Walch O, Huang Y, Forger D, Goldstein C. Sleep stage prediction with raw acceleration and photo-
//   plethysmography heart rate data derived from a consumer wearable device. SLEEP 42(12), zsz180 (2019).
//
// Dataset licence: Open Data Commons Attribution License v1.0. Attribution is a condition of use; see
// README.md. The dataset is NEVER committed here and is always supplied by `--dataset`.
//
// ── The mapping, and why each choice is the honest one ────────────────────────────────────────────────
//
// This dataset is an Apple Watch: a ~50 Hz raw accelerometer and a sparse PPG heart rate. NOOP's stager
// takes a 1 Hz gravity vector, a heart-rate stream, and R-R intervals. Three decisions bridge that, and
// each one can bias a result, so each is stated rather than buried:
//
//  1. GRAVITY ← per-second mean of the raw accelerometer. `SleepStagerV2.features` already collapses its
//     gravity stream to one value per second by averaging, so pre-averaging here is not an extra filter —
//     it is the same operation done earlier, and it keeps 31 subjects of 50 Hz data in memory. The absolute
//     SCALE still differs from a WHOOP gravity decode, and that is exactly the property the recipe was
//     built not to depend on: every motion threshold is a multiple of the night's OWN median per-second
//     jerk (`jerkScale`), never an absolute g. A benchmark on foreign hardware is a test of that claim.
//
//  2. R-R ← EMPTY. The dataset carries no beat-to-beat intervals, so `respRegularity` returns nil on every
//     epoch, `zrg` collapses to the constant 0, and the RSA term contributes exactly 0.0 to every emission.
//     The term is therefore INERT here, not corrupted: the recipe runs with one of its six inputs silent.
//     Any result below is a lower bound on what the same recipe does with an R-R stream present.
//
//  3. TIME ← the dataset's seconds-from-PSG-start, offset by a fixed multiple of 30 into positive unix
//     territory. Label epochs land on multiples of 30, so the recipe's wall-clock 30 s grid coincides with
//     the PSG scoring grid exactly and no epoch is compared against a label it only half overlaps.
//
// The session window handed to the stager is the LABELLED span — first scored epoch to last, plus 30 s.
// NOOP's own session detection is not exercised: this measures staging, which is the only thing
// `SleepStagerV2` does (detection still comes from V1).

/// One subject: the streams, the truth hypnogram on the same 30 s grid, and the window they share.
struct PSGSubject {
    let id: String
    /// Window start — a multiple of 30, aligned with truth epoch 0.
    let start: Int
    let end: Int
    let grav: [GravitySample]
    let hr: [HRSample]
    /// One entry per 30 s epoch of `[start, end)`. `nil` = the epoch carries no PSG score and is excluded
    /// from every metric rather than silently counted as wake.
    let truth: [String?]

    var scoredEpochs: Int { truth.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    /// Duration of the scored night in minutes — the stratification variable.
    var scoredMinutes: Double { Double(scoredEpochs) * 30.0 / 60.0 }
}

enum SleepAccel {

    /// A multiple of 30 near the present, so `t = 0` maps onto a 30 s wall-clock boundary and no timestamp
    /// is negative (the recipe's `((start + 29) / 30) * 30` truncates toward zero, which is only the
    /// intended floor for non-negative input).
    static let timeBase = 1_699_999_980

    /// Which whole second a fractional dataset timestamp belongs to. FLOOR, not round: the recipe's
    /// per-second aggregation buckets by integer second, so a sample at t = 0.9 s is inside second 0, and
    /// rounding would push it into second 1 and shift the motion series against the heart-rate series by
    /// up to a second. Floor is also the correct answer for the dataset's large negative times.
    static func wholeSecond(_ t: Double) -> Int { Int(t.rounded(.down)) }

    /// AASM stage codes as scored in `labels/*_labeled_sleep.txt`, mapped onto NOOP's four classes.
    /// N1+N2 → light and N3(+N4) → deep is the standard four-class collapse; anything else — including the
    /// dataset's unscored marker — becomes `nil` and is dropped from the denominator.
    static func stageForCode(_ code: Int) -> String? {
        switch code {
        case 0: return "wake"
        case 1, 2: return "light"
        case 3, 4: return "deep"
        case 5: return "rem"
        default: return nil     // -1 unscored, and any code this collapse does not claim to handle
        }
    }

    /// Locate the dataset root. Accepts either the extracted directory itself or its parent, so a user who
    /// unzipped without `-j` does not have to guess which level to pass.
    static func resolveRoot(_ path: String) -> String? {
        let fm = FileManager.default
        var candidates = [path]
        if let subs = try? fm.contentsOfDirectory(atPath: path) {
            candidates.append(contentsOf: subs.map { (path as NSString).appendingPathComponent($0) })
        }
        for c in candidates {
            var isDir: ObjCBool = false
            let labels = (c as NSString).appendingPathComponent("labels")
            if fm.fileExists(atPath: labels, isDirectory: &isDir), isDir.boolValue { return c }
        }
        return nil
    }

    /// Subject ids, from the label directory — a subject with no PSG hypnogram cannot be scored at all.
    static func subjectIDs(root: String) -> [String] {
        let dir = (root as NSString).appendingPathComponent("labels")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.compactMap { name -> String? in
            guard name.hasSuffix("_labeled_sleep.txt") else { return nil }
            return String(name.dropLast("_labeled_sleep.txt".count))
        }.sorted()
    }

    /// Load one subject. Returns nil when a required file is missing or the hypnogram has no scored epoch.
    static func load(root: String, id: String) -> PSGSubject? {
        let labelRows = readRows((root as NSString)
            .appendingPathComponent("labels/\(id)_labeled_sleep.txt"), expecting: 2)
        guard !labelRows.isEmpty else { return nil }

        // The truth grid: first scored epoch to last. Epoch times in the file are multiples of 30.
        var byEpoch: [Int: String] = [:]
        var minT = Int.max, maxT = Int.min
        for r in labelRows {
            let t = Int((r[0] / 30.0).rounded()) * 30
            guard let stage = stageForCode(Int(r[1].rounded())) else { continue }
            byEpoch[t] = stage
            minT = min(minT, t); maxT = max(maxT, t)
        }
        guard minT != Int.max else { return nil }

        let start = timeBase + minT
        let end = timeBase + maxT + 30
        let nEpochs = (end - start) / 30
        var truth = [String?](repeating: nil, count: nEpochs)
        for (t, s) in byEpoch {
            let i = (t - minT) / 30
            if i >= 0 && i < nEpochs { truth[i] = s }
        }

        // Each subject's motion and heart-rate files cover DAYS around the lab night — the earliest rows sit
        // four days before lights-out. Rows outside the recipe's own read window are dropped during the
        // read. This is provably loss-free rather than a convenience: `SleepStagerV2.stageSession` clips its
        // inputs to exactly `[start − padLo, end + padHi)` before doing anything else, so these are rows the
        // recipe would discard itself. Doing it here keeps 31 subjects of daytime 50 Hz data out of memory.
        let loSec = minT - V2Recipe.padLo
        let hiSec = maxT + 30 + V2Recipe.padHi

        let hr = readRows((root as NSString)
            .appendingPathComponent("heart_rate/\(id)_heartrate.txt"), expecting: 2)
            .compactMap { r -> HRSample? in
                let bpm = Int(r[1].rounded())
                let sec = wholeSecond(r[0])
                guard bpm > 0, bpm < 300, sec >= loSec, sec < hiSec else { return nil }
                return HRSample(ts: timeBase + sec, bpm: bpm)
            }
            .sorted { $0.ts < $1.ts }

        let grav = readAccelerationPerSecond((root as NSString)
            .appendingPathComponent("motion/\(id)_acceleration.txt"), loSec: loSec, hiSec: hiSec)

        return PSGSubject(id: id, start: start, end: end, grav: grav, hr: hr, truth: truth)
    }

    // MARK: - Parsing

    /// Read a whitespace/comma-separated numeric table, keeping rows that yield at least `expecting`
    /// values. Byte-level because the motion files run to millions of lines each and a per-line `String`
    /// allocation dominates the whole run.
    static func readRows(_ path: String, expecting: Int) -> [[Double]] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        var out: [[Double]] = []
        forEachRow(data, maxValues: expecting) { vals, n in
            if n >= expecting { out.append(Array(vals[0..<expecting])) }
        }
        return out
    }

    /// Read `motion/*_acceleration.txt` and collapse it to one `GravitySample` per whole second, the mean
    /// of every raw sample in that second. See the header note: this is the same per-second mean
    /// `SleepStagerV2.features` would compute, done during the read so 50 Hz never lands in memory.
    static func readAccelerationPerSecond(_ path: String,
                                          loSec: Int = Int.min, hiSec: Int = Int.max) -> [GravitySample] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        var sx = [Int: Double](), sy = [Int: Double](), sz = [Int: Double](), cnt = [Int: Int]()
        forEachRow(data, maxValues: 4) { vals, n in
            guard n >= 4 else { return }
            let t = wholeSecond(vals[0])
            if t < loSec || t >= hiSec { return }
            sx[t, default: 0] += vals[1]; sy[t, default: 0] += vals[2]; sz[t, default: 0] += vals[3]
            cnt[t, default: 0] += 1
        }
        var out: [GravitySample] = []
        out.reserveCapacity(cnt.count)
        for (t, c) in cnt {
            let d = Double(c)
            out.append(GravitySample(ts: timeBase + t, x: sx[t]! / d, y: sy[t]! / d, z: sz[t]! / d))
        }
        return out.sorted { $0.ts < $1.ts }
    }

    /// Walk `data` line by line, parsing up to `maxValues` numbers per line with `strtod`, and hand each
    /// row to `body`. Separators are commas and spaces/tabs; a line whose numbers run out early is passed
    /// with its count so the caller can drop it.
    private static func forEachRow(_ data: Data, maxValues: Int, _ body: ([Double], Int) -> Void) {
        var bytes = [UInt8](data)
        bytes.append(0)
        var vals = [Double](repeating: 0, count: maxValues)
        bytes.withUnsafeBufferPointer { buf in
            guard let raw = buf.baseAddress else { return }
            let base = UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self)
            let count = buf.count - 1
            var i = 0
            while i < count {
                var lineEnd = i
                while lineEnd < count && buf[lineEnd] != 0x0A { lineEnd += 1 }
                var p = i
                var n = 0
                while p < lineEnd && n < maxValues {
                    let c = buf[p]
                    // Only start a parse on something that can begin a number; otherwise `strtod` would
                    // skip trailing whitespace and swallow the FIRST number of the following line.
                    let numeric = (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E
                    if !numeric { p += 1; continue }
                    var endPtr: UnsafeMutablePointer<CChar>?
                    let v = strtod(base + p, &endPtr)
                    guard let e = endPtr else { break }
                    let consumed = UnsafePointer(e) - (base + p)
                    if consumed <= 0 { p += 1; continue }
                    vals[n] = v
                    n += 1
                    p += consumed
                }
                body(vals, n)
                i = lineEnd + 1
            }
        }
    }
}
