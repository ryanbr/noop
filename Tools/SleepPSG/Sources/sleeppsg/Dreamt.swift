import Foundation
import WhoopProtocol

// Dreamt — read PhysioNet DREAMT (the 64 Hz Empatica E4 files) and present each subject as the streams a
// NOOP stager takes, plus the PSG hypnogram to score against.
//
//   Wang K, Yang J, Shetty A, Dunn J. DREAMT: Dataset for Real-time sleep stage EstimAtion using
//   Multisensor wearable Technology (version 2.2.0). PhysioNet (2026). https://doi.org/10.13026/3f7y-2d80
//   Wang WK, Yang J, Hershkovich L, et al. Proceedings of the fifth Conference on Health, Inference, and
//   Learning, PMLR 248:380–396 (2024).
//
// DREAMT is restricted-access (PhysioNet Restricted Health Data License 1.5.0; each user signs the data use
// agreement and downloads it themselves). The files are NEVER committed here, are always supplied by
// `--dataset`, and nothing this tool prints is per-epoch data — only cohort aggregates and per-stratum counts.
//
// ── Why this dataset, and what it changes ───────────────────────────────────────────────────────────────
//
// `sleep-accel` carries no beat-to-beat intervals, so on it the recipe's RSA respiration term is silent on
// every epoch. DREAMT's E4 reports inter-beat intervals from its PPG, so here the term is LIVE — the only
// PSG-labelled reference NOOP has where all six of the recipe's inputs run.
//
// It is also a sleep-clinic cohort: most subjects were referred for suspected sleep apnoea, and their
// sleep is more fragmented, with more wake and less N3/REM, than a healthy night. PR #348 tuned the recipe's
// priors on it and PR #437 reverted that 48 h later, because the cohort's wake base rate had been absorbed
// into a prior applied to everybody. So this reader reports each subject's AHI beside them, the report
// stratifies by it, and nothing here fits a constant to the cohort's base rates.
//
// ── The mapping ────────────────────────────────────────────────────────────────────────────────────────
//
//  1. GRAVITY ← per-second mean of ACC_X/Y/Z (the E4's 32 Hz accelerometer in 1/64 g, forward-filled to
//     64 Hz in the file). Same collapse as `SleepAccel`, for the same reason: the recipe's motion thresholds
//     are multiples of the night's own median jerk, never an absolute g.
//
//  2. HR ← the E4's HR column at each whole second (the device's 1 Hz PPG heart rate, forward-filled).
//
//  3. R-R ← the IBI column, turned back into beats. The values are SECONDS in the files (0.796875 = 51/64 s),
//     although the dataset page labels the column ms. The file forward-fills each inter-beat interval over the
//     64 Hz rows until the next one, so a beat shows as the value CHANGING, and two consecutive beats with the
//     same (1/64 s-quantised) interval show as one change. Each change at `t2` with value `v2`, after the
//     previous change at `t1` with value `v1`, is therefore resolved by arithmetic, not by guess:
//       t2 − t1 = v2            the two changes are consecutive beats (the common case, ~83 %);
//       t2 − t1 = v1 + v2       one beat at t1 + v1 repeated the interval v1, hidden by the forward fill;
//       t2 − t1 = 2·v1 + v2     two such hidden repeats;
//       anything else           a detection gap: the E4 dropped beats, and `t2` starts a new run.
//     Each beat becomes `RRInterval(ts: whole second of the beat, rrMs)` — the per-second bucketing a WHOOP
//     delivers, and the one `SleepStagerV2.features` reads.
//
//  4. TIME ← seconds from the start of the file, shifted so the FIRST PSG-SCORED EPOCH starts on a multiple
//     of 30. DREAMT's scoring grid does not start at t = 0 (on the files checked it starts at 24 s past a
//     multiple of 30), so aligning on it keeps the recipe's wall-clock 30 s grid exactly on the PSG grid.
//
//  5. LABELS ← `Sleep_Stage` at each epoch: W → wake, N1/N2 → light, N3 → deep, R → rem. `P` (the
//     preparation period before lights-out) and `Missing` are unscored and leave the denominator.

/// A DREAMT subject's metadata, from `participant_info.csv`. Only what the report stratifies on.
struct DreamtInfo {
    let age: Double?
    let sex: String
    let bmi: Double?
    /// Apnoea–hypopnoea index, events per hour. The cohort's defining variable.
    let ahi: Double?
}

enum Dreamt {

    /// A multiple of 30, as in `SleepAccel.timeBase`.
    static let timeBase = 1_699_999_980

    static func isDreamtRoot(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("data_64Hz"))
            && FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("participant_info.csv"))
    }

    /// Accept the directory holding `data_64Hz/` or its parent.
    static func resolveRoot(_ path: String) -> String? {
        if isDreamtRoot(path) { return path }
        let subs = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        for s in subs.sorted() {
            let c = (path as NSString).appendingPathComponent(s)
            if isDreamtRoot(c) { return c }
        }
        return nil
    }

    /// `participant_info.csv`: SID, AGE, GENDER, BMI, OAHI, AHI, … — quoted fields may contain commas.
    static func participants(root: String) -> [String: DreamtInfo] {
        guard let text = try? String(contentsOfFile: (root as NSString).appendingPathComponent("participant_info.csv"),
                                     encoding: .utf8) else { return [:] }
        var out: [String: DreamtInfo] = [:]
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let f = splitCSV(String(line))
            guard f.count >= 6 else { continue }
            out[f[0]] = DreamtInfo(age: Double(f[1]), sex: f[2], bmi: Double(f[3]), ahi: Double(f[5]))
        }
        return out
    }

    static func subjectIDs(root: String) -> [String] {
        let dir = (root as NSString).appendingPathComponent("data_64Hz")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.compactMap { name -> String? in
            guard name.hasSuffix("_whole_df.csv") else { return nil }
            return String(name.dropLast("_whole_df.csv".count))
        }.sorted()
    }

    /// Stage codes as parsed from the file. `prep` and `missing` are unscored.
    enum Code: Int8 { case none = -3, prep = -2, missing = -1, wake = 0, n1 = 1, n2 = 2, n3 = 3, rem = 5 }

    static func label(_ c: Code) -> String? {
        switch c {
        case .wake: return "wake"
        case .n1, .n2: return "light"
        case .n3: return "deep"
        case .rem: return "rem"
        default: return nil
        }
    }

    /// Load one subject: nil when the file is missing or carries no scored epoch.
    static func load(root: String, id: String, info: DreamtInfo?) -> PSGSubject? {
        let path = (root as NSString).appendingPathComponent("data_64Hz/\(id)_whole_df.csv")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }

        // One pass over the 64 Hz rows. Everything is kept per whole second of FILE time; the shift onto
        // the scoring grid is applied at the end, once the first scored epoch is known.
        var gx = [Int: Double](), gy = [Int: Double](), gz = [Int: Double](), gn = [Int: Int]()
        var hrAt = [Int: Double]()
        var stageAt: [(t: Double, code: Code)] = []
        var ibiChanges: [(t: Double, v: Double)] = []
        var lastIbiBytes: [UInt8] = []
        var lastCode = Code.none

        forEachLine(data) { line in
            // TIMESTAMP,BVP,ACC_X,ACC_Y,ACC_Z,TEMP,EDA,HR,IBI,Sleep_Stage,…
            guard let t = line.double(0) else { return }
            let sec = Int(t.rounded(.down))
            if let x = line.double(2), let y = line.double(3), let z = line.double(4) {
                gx[sec, default: 0] += x; gy[sec, default: 0] += y; gz[sec, default: 0] += z; gn[sec, default: 0] += 1
            }
            if hrAt[sec] == nil, let h = line.double(7), h > 0 { hrAt[sec] = h }
            let ibi = line.bytes(8)
            if !ibi.isEmpty && ibi != lastIbiBytes {
                lastIbiBytes = ibi
                if let v = line.double(8), v > 0 { ibiChanges.append((t, v)) }
            }
            let code = stageCode(line.bytes(9))
            if code != lastCode { stageAt.append((t, code)); lastCode = code }
        }

        // The scoring grid starts at the first scored stage change.
        guard let firstScored = stageAt.first(where: { label($0.code) != nil }) else { return nil }
        let offset = Int(firstScored.t.rounded())
        // Epoch k covers file time [offset + 30k, offset + 30k + 30); its label is the stage in force at the
        // epoch's midpoint (the stage column only ever changes on the grid, so any point inside agrees).
        let lastT = gn.keys.max() ?? offset
        let nEpochs = max(0, (lastT + 1 - offset) / 30)          // whole epochs only; a trailing partial is dropped
        var truth = [String?](repeating: nil, count: nEpochs)
        var si = 0
        for k in 0..<nEpochs {
            let mid = Double(offset + 30 * k) + 15
            while si + 1 < stageAt.count && stageAt[si + 1].t <= mid { si += 1 }
            truth[k] = stageAt[si].t <= mid ? label(stageAt[si].code) : nil
        }
        // Trim unscored epochs at both ends so the window is first scored epoch → last scored epoch.
        guard let lastScored = truth.lastIndex(where: { $0 != nil }) else { return nil }
        truth = Array(truth[0...lastScored])

        let start = timeBase
        let end = timeBase + 30 * truth.count
        let loSec = offset - V2Recipe.padLo
        let hiSec = offset + 30 * truth.count + V2Recipe.padHi
        func wall(_ fileSec: Int) -> Int { timeBase + fileSec - offset }

        var grav: [GravitySample] = []
        grav.reserveCapacity(gn.count)
        for (s, c) in gn where s >= loSec && s < hiSec {
            let d = Double(c)
            grav.append(GravitySample(ts: wall(s), x: gx[s]! / d, y: gy[s]! / d, z: gz[s]! / d))
        }
        grav.sort { $0.ts < $1.ts }

        var hr: [HRSample] = []
        for (s, h) in hrAt where s >= loSec && s < hiSec {
            let bpm = Int(h.rounded())
            if bpm > 0 && bpm < 300 { hr.append(HRSample(ts: wall(s), bpm: bpm)) }
        }
        hr.sort { $0.ts < $1.ts }

        let beats = reconstructBeats(ibiChanges)
        var rr: [RRInterval] = []
        rr.reserveCapacity(beats.count)
        for b in beats {
            let s = Int(b.t.rounded(.down))
            guard s >= loSec && s < hiSec else { continue }
            rr.append(RRInterval(ts: wall(s), rrMs: Int((b.v * 1000).rounded()), srcChannel: nil))
        }

        return PSGSubject(id: id, start: start, end: end, grav: grav, hr: hr, truth: truth, rr: rr,
                          ahi: info?.ahi)
    }

    // MARK: - Beats from the forward-filled IBI column

    /// See the header, point 3. Tolerance is one and a half 64 Hz samples: the E4 quantises intervals to
    /// 1/64 s and the file stamps each change on a 64 Hz row.
    static func reconstructBeats(_ changes: [(t: Double, v: Double)]) -> [(t: Double, v: Double)] {
        let tol = 1.5 / 64
        var out: [(t: Double, v: Double)] = []
        out.reserveCapacity(changes.count + changes.count / 8)
        var prev: (t: Double, v: Double)?
        for c in changes {
            if let p = prev {
                let d = c.t - p.t
                if abs(d - (p.v + c.v)) <= tol {
                    out.append((p.t + p.v, p.v))
                } else if abs(d - (2 * p.v + c.v)) <= tol {
                    out.append((p.t + p.v, p.v)); out.append((p.t + 2 * p.v, p.v))
                }
            }
            out.append(c)
            prev = c
        }
        return out
    }

    // MARK: - Parsing

    static func stageCode(_ b: [UInt8]) -> Code {
        switch b {
        case [0x50]: return .prep                       // P
        case [0x57]: return .wake                       // W
        case [0x4E, 0x31]: return .n1                   // N1
        case [0x4E, 0x32]: return .n2                   // N2
        case [0x4E, 0x33]: return .n3                   // N3
        case [0x52]: return .rem                        // R
        default: return b.isEmpty ? .none : .missing    // "Missing", or anything this reader does not claim
        }
    }

    /// One CSV line as field ranges over the file's bytes. No per-line `String`: the files are ~2 M lines.
    struct Line {
        let base: UnsafePointer<CChar>
        let buf: UnsafeBufferPointer<UInt8>
        var starts: [Int]
        var ends: [Int]
        func bytes(_ i: Int) -> [UInt8] {
            guard i < starts.count else { return [] }
            return Array(buf[starts[i]..<ends[i]])
        }
        func double(_ i: Int) -> Double? {
            guard i < starts.count, ends[i] > starts[i] else { return nil }
            var endPtr: UnsafeMutablePointer<CChar>?
            let v = strtod(base + starts[i], &endPtr)
            guard let e = endPtr, UnsafePointer(e) - (base + starts[i]) > 0 else { return nil }
            return v.isFinite ? v : nil
        }
    }

    /// Walk the file line by line (the header is skipped) and hand each line's first ten fields to `body`.
    static func forEachLine(_ data: Data, _ body: (Line) -> Void) {
        var bytes = [UInt8](data)
        bytes.append(0)
        bytes.withUnsafeBufferPointer { buf in
            guard let raw = buf.baseAddress else { return }
            let base = UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self)
            let count = buf.count - 1
            var i = 0
            var first = true
            var line = Line(base: base, buf: buf, starts: [], ends: [])
            line.starts.reserveCapacity(16); line.ends.reserveCapacity(16)
            while i < count {
                var lineEnd = i
                while lineEnd < count && buf[lineEnd] != 0x0A { lineEnd += 1 }
                var e = lineEnd
                if e > i && buf[e - 1] == 0x0D { e -= 1 }
                if first { first = false; i = lineEnd + 1; continue }
                line.starts.removeAll(keepingCapacity: true); line.ends.removeAll(keepingCapacity: true)
                var fs = i
                var p = i
                while p <= e && line.starts.count < 10 {
                    if p == e || buf[p] == 0x2C {
                        line.starts.append(fs); line.ends.append(p); fs = p + 1
                    }
                    p += 1
                }
                body(line)
                i = lineEnd + 1
            }
        }
    }

    /// Minimal CSV split honouring double quotes (participant_info's history column holds commas).
    static func splitCSV(_ s: String) -> [String] {
        var out: [String] = [], cur = "", q = false
        for ch in s {
            if ch == "\"" { q.toggle() } else if ch == "," && !q { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        out.append(cur)
        return out
    }
}
