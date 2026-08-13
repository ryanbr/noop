import Foundation

// ReTools — offline reverse-engineering aids over the SAME `WhoopProtocol` decoder the app runs.
//
// These are DEV TOOLING, not shipped on-device logic: every function here takes already-decoded
// `ParsedFrame`s (the output of `parseFrame`) plus the raw bytes and reports *about* the decode —
// which bytes are still unknown, what changed between two captures, what a strap actually banked, and
// how a candidate field tracks a ground-truth value. They define no new wire semantics, so unlike the
// decoders themselves they need no Kotlin twin, and because they read captured records they run
// entirely offline (no device, no BLE, no battery/perf cost, no new capture mode).
//
// The four tools:
//   • coverage(_:)    — per (type, version) byte-coverage map + per-unknown-offset variance. The
//                       RE worklist: which payload bytes the schema does NOT yet name, and whether
//                       each is constant (flag/padding) or varies (a live field worth decoding).
//   • diff(_:_:)      — value-set diff of the same record layout across two captures. Feed it a
//                       flag-on vs flag-off pair (e.g. `enable_spo2`) and the feature-linked bytes
//                       fall out as the offsets whose value set changed.
//   • inventory(_:)   — one-glance census: which types/versions a capture holds, counts, ok/crc
//                       rates, timestamp span, length spread. Tells you what you actually captured.
//   • groundTruth(…)  — align a decoded field to timestamped truth (what the WHOOP app displayed)
//                       and score it (MAE, bias, Pearson r), turning "looks right" into a number.

public enum ReTools {

    // MARK: - Shared record model

    /// A decoded capture record: the parsed frame, the raw bytes it came from, and the provenance the
    /// capture tool attaches (`ts_ms`, `hr`) that the decoder ignores but alignment/diff use.
    public struct Record: Equatable {
        public let frame: ParsedFrame
        public let bytes: [UInt8]
        public let tsMs: Int?
        public let hr: Int?
        public init(frame: ParsedFrame, bytes: [UInt8], tsMs: Int? = nil, hr: Int? = nil) {
            self.frame = frame; self.bytes = bytes; self.tsMs = tsMs; self.hr = hr
        }
    }

    /// The grouping key every tool shares. A `HISTORICAL_DATA` (type-47) record splits by its version
    /// byte — which the interpreter surfaces as `seq`, the type-47 layout selector — so v18/v20/v21/v26
    /// are analysed as the distinct layouts they are. Every other packet type groups by name alone.
    public static func groupKey(_ f: ParsedFrame) -> String {
        if f.typeName == "HISTORICAL_DATA", let v = f.seq { return "HISTORICAL_DATA/v\(v)" }
        return f.typeName
    }

    /// The set of byte offsets a frame's decoded fields cover (each field spans `off ..< off+len`).
    private static func coveredOffsets(_ f: ParsedFrame) -> Set<Int> {
        var s = Set<Int>()
        for field in f.fields where field.len > 0 {
            for o in field.off ..< (field.off + field.len) { s.insert(o) }
        }
        return s
    }

    /// The modal (most common) byte length in a bag of records — the dominant layout width, so a lone
    /// truncated frame can't skew per-offset statistics. Ties break toward the larger length.
    private static func modalLength(_ recs: [Record]) -> Int {
        var counts: [Int: Int] = [:]
        for r in recs { counts[r.bytes.count, default: 0] += 1 }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }?.key ?? 0
    }

    // MARK: - A) Coverage map

    /// One uncovered byte offset's variance across a group — the signal for whether it's worth decoding.
    public struct ByteStat: Equatable {
        public let offset: Int
        public let distinctValues: Int
        public let minValue: Int
        public let maxValue: Int
        public let sampleCount: Int
        /// A single value across every sample: almost always a flag, reserved, or padding byte.
        public var constant: Bool { distinctValues <= 1 }
    }

    public struct GroupCoverage: Equatable {
        public let key: String
        public let frameCount: Int
        public let frameLen: Int
        public let coveredBytes: Int
        public let totalBytes: Int
        /// Uncovered offsets only (the RE worklist), each with its cross-frame variance, offset-ascending.
        public let unknownBytes: [ByteStat]
        /// Mean per-offset Shannon entropy (bits/byte, 0–8) over the unknown offsets — for EACH unknown
        /// byte position, the entropy of its value distribution ACROSS frames, then averaged. This is
        /// the encrypted-vs-merely-unknown test done right: a value near 8 means every byte position is
        /// random over time (ciphered/compressed), while structured plaintext — even a payload whose
        /// offsets each hold a *different* constant — stays near 0. It is NOT pooled across offsets, so
        /// cross-position variety can't masquerade as randomness. Bounded above by log2(unknownSampleCount),
        /// so it's meaningless until you have many frames — read it with `unknownSampleCount` (= frames).
        public let unknownEntropyBits: Double
        /// Number of same-layout frames the per-offset entropy was measured over (the entropy ceiling is
        /// log2 of this). NOT the byte count.
        public let unknownSampleCount: Int
        public var coveragePct: Double { totalBytes == 0 ? 0 : Double(coveredBytes) / Double(totalBytes) * 100 }
        /// A heuristic flag, deliberately conservative: near-max per-offset entropy over enough frames
        /// for the 8-bit ceiling to be reachable (log2(256)=8). NOT proof of encryption (high-entropy
        /// plaintext exists) — a prompt to investigate, which is why the entropy and frame count sit
        /// beside it.
        public var likelyEncrypted: Bool { unknownEntropyBits >= 7.5 && unknownSampleCount >= 256 }
    }

    /// Shannon entropy in bits/byte (0–8) over a byte multiset.
    private static func shannonBits(_ bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        for b in bytes { counts[Int(b)] += 1 }
        let n = Double(bytes.count)
        var h = 0.0
        for c in counts where c > 0 {
            let p = Double(c) / n
            h -= p * (log(p) / log(2))
        }
        return h
    }

    /// Per (type, version): how much of the frame the schema already names, and for every byte it does
    /// NOT, how that byte varies across the capture. Constant unknowns are likely flags/padding; the
    /// varying ones sitting next to known sensor fields are where the undecoded signal lives.
    public static func coverage(_ records: [Record]) -> [GroupCoverage] {
        let groups = Dictionary(grouping: records, by: { groupKey($0.frame) })
        var out: [GroupCoverage] = []
        for (key, recs) in groups {
            let len = modalLength(recs)
            let sized = recs.filter { $0.bytes.count == len }
            guard len > 0, !sized.isEmpty else {
                out.append(GroupCoverage(key: key, frameCount: recs.count, frameLen: len,
                                         coveredBytes: 0, totalBytes: len, unknownBytes: [],
                                         unknownEntropyBits: 0, unknownSampleCount: 0))
                continue
            }
            // Union the covered offsets across the group so a conditional field present in only some
            // frames still counts as decoded, never as an "unknown".
            var covered = Set<Int>()
            for r in sized { covered.formUnion(coveredOffsets(r.frame)) }
            var unknown: [ByteStat] = []
            var offsetEntropies: [Double] = []   // per-offset entropy across frames — averaged, never pooled
            for off in 0 ..< len where !covered.contains(off) {
                var distinct = Set<Int>(); var lo = Int.max; var hi = Int.min
                var column: [UInt8] = []; column.reserveCapacity(sized.count)
                for r in sized {
                    let byte = r.bytes[off]; let v = Int(byte); distinct.insert(v)
                    lo = min(lo, v); hi = max(hi, v); column.append(byte)
                }
                offsetEntropies.append(shannonBits(column))
                unknown.append(ByteStat(offset: off, distinctValues: distinct.count,
                                        minValue: lo, maxValue: hi, sampleCount: sized.count))
            }
            let meanEntropy = offsetEntropies.isEmpty
                ? 0 : offsetEntropies.reduce(0, +) / Double(offsetEntropies.count)
            let coveredInLen = covered.filter { $0 < len }.count
            out.append(GroupCoverage(key: key, frameCount: recs.count, frameLen: len,
                                     coveredBytes: coveredInLen, totalBytes: len,
                                     unknownBytes: unknown.sorted { $0.offset < $1.offset },
                                     unknownEntropyBits: meanEntropy, unknownSampleCount: sized.count))
        }
        return out.sorted { $0.key < $1.key }
    }

    // MARK: - B) Capture diff

    public struct OffsetDiff: Equatable {
        public let offset: Int
        public let covered: Bool
        public let aValues: [Int]
        public let bValues: [Int]
        /// The two captures share NO value at this offset — the strongest feature-linked signal.
        public var disjoint: Bool { Set(aValues).isDisjoint(with: Set(bValues)) }
    }

    public struct GroupDiff: Equatable {
        public let key: String
        public let inA: Bool
        public let inB: Bool
        /// Modal frame length on each side (0 for an absent side). When these differ, one capture's
        /// layout grew/shrank — often the whole point (enabling a feature can ADD trailing bytes), and
        /// `changedOffsets` only spans the overlap, so those extra bytes are reported here, not there.
        public let lenA: Int
        public let lenB: Int
        /// Offsets present in BOTH captures (up to the shorter length) whose value set differs (empty
        /// when the overlap matches byte for byte). Only populated for shared keys.
        public let changedOffsets: [OffsetDiff]
        /// The layouts are different widths — extra bytes on the longer side are NOT in `changedOffsets`.
        public var lengthDiffers: Bool { inA && inB && lenA != lenB }
    }

    /// Diff two captures by record layout. Keys in only one side surface as presence differences (a
    /// record type/version one capture banked and the other didn't). For a shared layout, every offset
    /// whose observed value set changed is reported — flip one device-config flag between the two
    /// captures and the bytes that flag drives are exactly the changed (ideally disjoint) offsets.
    public static func diff(_ a: [Record], _ b: [Record]) -> [GroupDiff] {
        let ga = Dictionary(grouping: a, by: { groupKey($0.frame) })
        let gb = Dictionary(grouping: b, by: { groupKey($0.frame) })
        var out: [GroupDiff] = []
        for key in Set(ga.keys).union(gb.keys) {
            let ra = ga[key], rb = gb[key]
            guard let ra, let rb else {
                out.append(GroupDiff(key: key, inA: ra != nil, inB: rb != nil,
                                     lenA: ra.map(modalLength) ?? 0, lenB: rb.map(modalLength) ?? 0,
                                     changedOffsets: []))
                continue
            }
            let lenA = modalLength(ra), lenB = modalLength(rb)
            let sa = ra.filter { $0.bytes.count == lenA }, sb = rb.filter { $0.bytes.count == lenB }
            // Union covered offsets across A's frames so a conditional field still reads as "named".
            var coveredA = Set<Int>()
            for r in sa { coveredA.formUnion(coveredOffsets(r.frame)) }
            var changed: [OffsetDiff] = []
            for off in 0 ..< min(lenA, lenB) {
                let va = Set(sa.map { Int($0.bytes[off]) })
                let vb = Set(sb.map { Int($0.bytes[off]) })
                if va != vb {
                    changed.append(OffsetDiff(offset: off, covered: coveredA.contains(off),
                                              aValues: va.sorted(), bValues: vb.sorted()))
                }
            }
            out.append(GroupDiff(key: key, inA: true, inB: true, lenA: lenA, lenB: lenB, changedOffsets: changed))
        }
        return out.sorted { $0.key < $1.key }
    }

    // MARK: - C) Inventory

    public struct GroupInventory: Equatable {
        public let key: String
        public let count: Int
        public let okCount: Int
        public let crcOkCount: Int
        public let firstTsMs: Int?
        public let lastTsMs: Int?
        public let minLen: Int
        public let maxLen: Int
    }

    /// A census of a capture: what types/versions it holds, how many of each, how many decoded and
    /// passed CRC, the timestamp span, and the frame-length spread. The fastest way to see "this strap
    /// banked a v21 we've never captured" before decoding a single byte.
    public static func inventory(_ records: [Record]) -> [GroupInventory] {
        let groups = Dictionary(grouping: records, by: { groupKey($0.frame) })
        return groups.map { key, recs in
            let ts = recs.compactMap { $0.tsMs }
            let lens = recs.map { $0.bytes.count }
            return GroupInventory(
                key: key, count: recs.count,
                okCount: recs.filter { $0.frame.ok }.count,
                crcOkCount: recs.filter { $0.frame.crcOK == true }.count,
                firstTsMs: ts.min(), lastTsMs: ts.max(),
                minLen: lens.min() ?? 0, maxLen: lens.max() ?? 0)
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }

    // MARK: - D) Ground-truth alignment

    public struct TruthPoint: Equatable {
        public let tsMs: Int
        public let value: Double
        public init(tsMs: Int, value: Double) { self.tsMs = tsMs; self.value = value }
    }

    public struct Residual: Equatable {
        public let tsMs: Int
        public let truth: Double
        public let decoded: Double?
        public let dtMs: Int
    }

    public struct Score: Equatable {
        public let fieldName: String
        public let n: Int
        public let meanAbsError: Double?
        public let bias: Double?
        public let pearson: Double?
        public let residuals: [Residual]
    }

    /// Score how well a decoded field tracks timestamped ground truth (what the official app showed).
    /// Each truth point is matched to the nearest record *that actually carries a numeric decode of
    /// `fieldName`* within `maxDtMs` — NOT merely the nearest record of any type, because on a real
    /// interleaved capture the closest frame by time is usually some other packet that doesn't carry
    /// the metric. The paired values are scored: mean-absolute-error, bias (mean signed error), and
    /// Pearson r. This is the instrument-first check that lets a candidate PPG→HRV / SpO₂ mapping be
    /// *validated*, not eyeballed — and it's honest about coverage (`n` = truth points that found a
    /// field-bearing record in range; a `nil` decoded residual means none did).
    public static func groundTruth(records: [Record], truth: [TruthPoint],
                                   fieldName: String, maxDtMs: Int = 60_000) -> Score {
        // Only records that are timestamped AND carry a numeric value for this field are candidates —
        // pairing `decoded` to the field-bearing record, never to a nearer frame that lacks it.
        let candidates: [(ts: Int, value: Double)] = records.compactMap { r in
            guard let ts = r.tsMs, let v = r.frame.parsed[fieldName]?.doubleValue else { return nil }
            return (ts, v)
        }
        var residuals: [Residual] = []
        for t in truth.sorted(by: { $0.tsMs < $1.tsMs }) {
            var bestValue: Double?; var bestDt = Int.max
            for c in candidates {
                let dt = abs(c.ts - t.tsMs)
                if dt < bestDt { bestDt = dt; bestValue = c.value }
            }
            let decoded = (bestValue != nil && bestDt <= maxDtMs) ? bestValue : nil
            residuals.append(Residual(tsMs: t.tsMs, truth: t.value, decoded: decoded, dtMs: bestDt))
        }
        let pairs = residuals.compactMap { r in r.decoded.map { (t: r.truth, d: $0) } }
        guard !pairs.isEmpty else {
            return Score(fieldName: fieldName, n: 0, meanAbsError: nil, bias: nil, pearson: nil,
                         residuals: residuals)
        }
        let n = Double(pairs.count)
        let mae = pairs.reduce(0.0) { $0 + abs($1.d - $1.t) } / n
        let bias = pairs.reduce(0.0) { $0 + ($1.d - $1.t) } / n
        return Score(fieldName: fieldName, n: pairs.count, meanAbsError: mae, bias: bias,
                     pearson: pearson(pairs), residuals: residuals)
    }

    // MARK: - E) gravity2 characterization (issue #1308)

    /// One axis of the gravity-vs-gravity2 comparison. The V24 schema decodes a SECOND gravity/accel
    /// triplet (`gravity2_x/y/z` @56/60/64) alongside the primary one (`gravity_x/y/z` @40/44/48), but
    /// nothing consumes it and its semantics are unknown (goose decodes it too and doesn't know either).
    /// These stats are the instrument for finding out what it is — never a metric.
    public struct GravityAxisPair: Equatable {
        public let axis: String          // "x" / "y" / "z"
        public let n: Int
        public let meanPrimary: Double
        public let meanSecond: Double
        public let meanDelta: Double      // mean(second - primary)
        public let maxAbsDelta: Double
        public let correlation: Double?   // corr(primary, second)
    }

    public struct GravityPairReport: Equatable {
        public let key: String
        public let sampleCount: Int
        public let axes: [GravityAxisPair]
        /// Records skipped because `skin_contact == 0` (off-wrist): gravity/gravity2 are meaningless there
        /// (zeroed/stale), so pooling them would skew the verdict. Reported so the coverage is honest.
        public let excludedOffWrist: Int
        /// Every axis tracks the primary to within `epsilon` on every sample → gravity2 is just a copy of
        /// gravity (no new information). If false, it carries something the primary triplet doesn't.
        public let identicalToPrimary: Bool
    }

    /// Characterize the unknown V24 `gravity2` triplet against the primary `gravity` triplet, per axis:
    /// is it an identical copy, a constant offset, a scaled/filtered version, or decorrelated (a different
    /// sensor)? Pairs the two triplets on records that carry both, per group. Off-wrist records
    /// (`skin_contact == 0`) are excluded — like every other V24 biometric — because gravity is
    /// meaningless off the wrist and would corrupt the comparison. Pure instrumentation for issue
    /// #1308 — feeds no score; the point is to learn what gravity2 is from a real 5/MG capture.
    public static func gravityPair(_ records: [Record], epsilon: Double = 1e-4) -> [GravityPairReport] {
        let groups = Dictionary(grouping: records, by: { groupKey($0.frame) })
        var out: [GravityPairReport] = []
        for (key, recs) in groups {
            var report: [String: (p: [Double], s: [Double])] = ["x": ([], []), "y": ([], []), "z": ([], [])]
            var excluded = 0
            for r in recs {
                // Gate on the on-wrist contact byte, exactly as the rest of the V24 biometric suite does.
                if r.frame.parsed["skin_contact"]?.intValue == 0 { excluded += 1; continue }
                for axis in ["x", "y", "z"] {
                    guard let p = r.frame.parsed["gravity_\(axis)"]?.doubleValue,
                          let s = r.frame.parsed["gravity2_\(axis)"]?.doubleValue else { continue }
                    report[axis]!.p.append(p); report[axis]!.s.append(s)
                }
            }
            var axes: [GravityAxisPair] = []
            var allIdentical = true
            for axis in ["x", "y", "z"] {
                let p = report[axis]!.p, s = report[axis]!.s
                guard !p.isEmpty else { continue }
                let n = Double(p.count)
                let deltas = zip(p, s).map { $0.1 - $0.0 }
                let maxAbs = deltas.map(abs).max() ?? 0
                if maxAbs > epsilon { allIdentical = false }
                axes.append(GravityAxisPair(
                    axis: axis, n: p.count,
                    meanPrimary: p.reduce(0, +) / n, meanSecond: s.reduce(0, +) / n,
                    meanDelta: deltas.reduce(0, +) / n, maxAbsDelta: maxAbs,
                    correlation: pearson(Array(zip(p, s).map { (t: $0.0, d: $0.1) }))))
            }
            guard !axes.isEmpty else { continue }
            out.append(GravityPairReport(key: key, sampleCount: axes.map { $0.n }.max() ?? 0,
                                         axes: axes, excludedOffWrist: excluded,
                                         identicalToPrimary: allIdentical))
        }
        return out.sorted { $0.key < $1.key }
    }

    /// Pearson correlation over (truth, decoded) pairs; nil when fewer than two points or either side
    /// has zero variance (a correlation would be undefined, so we say so rather than emit a fake 0/NaN).
    private static func pearson(_ pairs: [(t: Double, d: Double)]) -> Double? {
        guard pairs.count >= 2 else { return nil }
        let n = Double(pairs.count)
        let mt = pairs.reduce(0.0) { $0 + $1.t } / n
        let md = pairs.reduce(0.0) { $0 + $1.d } / n
        var cov = 0.0, vt = 0.0, vd = 0.0
        for p in pairs {
            let dt = p.t - mt, dd = p.d - md
            cov += dt * dd; vt += dt * dt; vd += dd * dd
        }
        guard vt > 0, vd > 0 else { return nil }
        return cov / (vt.squareRoot() * vd.squareRoot())
    }
}
