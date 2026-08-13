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
        /// Shannon entropy (bits/byte, 0–8) of ALL unknown bytes pooled across the group. The
        /// encrypted-vs-merely-unknown test: a value near 8 with a large sample means the undecoded
        /// payload is statistically random (ciphered or compressed); a low value means it's structured
        /// plaintext you simply haven't decoded yet. Meaningless on a tiny sample — read it with
        /// `unknownSampleCount`.
        public let unknownEntropyBits: Double
        public let unknownSampleCount: Int
        public var coveragePct: Double { totalBytes == 0 ? 0 : Double(coveredBytes) / Double(totalBytes) * 100 }
        /// A heuristic flag, deliberately conservative: high pooled entropy over a sample big enough to
        /// trust. NOT proof of encryption (high-entropy plaintext exists) — a prompt to investigate,
        /// which is why the raw entropy and sample size are exposed alongside it.
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
            var pooled: [UInt8] = []          // every unknown byte, all offsets × all frames — the entropy sample
            for off in 0 ..< len where !covered.contains(off) {
                var distinct = Set<Int>(); var lo = Int.max; var hi = Int.min
                for r in sized {
                    let v = Int(r.bytes[off]); distinct.insert(v)
                    lo = min(lo, v); hi = max(hi, v)
                    pooled.append(r.bytes[off])
                }
                unknown.append(ByteStat(offset: off, distinctValues: distinct.count,
                                        minValue: lo, maxValue: hi, sampleCount: sized.count))
            }
            let coveredInLen = covered.filter { $0 < len }.count
            out.append(GroupCoverage(key: key, frameCount: recs.count, frameLen: len,
                                     coveredBytes: coveredInLen, totalBytes: len,
                                     unknownBytes: unknown.sorted { $0.offset < $1.offset },
                                     unknownEntropyBits: shannonBits(pooled), unknownSampleCount: pooled.count))
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
        /// Offsets present in BOTH captures whose value set differs (empty when the layouts match byte
        /// for byte). Only populated for shared keys.
        public let changedOffsets: [OffsetDiff]
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
                out.append(GroupDiff(key: key, inA: ra != nil, inB: rb != nil, changedOffsets: []))
                continue
            }
            let lenA = modalLength(ra), lenB = modalLength(rb)
            let sa = ra.filter { $0.bytes.count == lenA }, sb = rb.filter { $0.bytes.count == lenB }
            let coveredA = sa.first.map { coveredOffsets($0.frame) } ?? []
            var changed: [OffsetDiff] = []
            for off in 0 ..< min(lenA, lenB) {
                let va = Set(sa.map { Int($0.bytes[off]) })
                let vb = Set(sb.map { Int($0.bytes[off]) })
                if va != vb {
                    changed.append(OffsetDiff(offset: off, covered: coveredA.contains(off),
                                              aValues: va.sorted(), bValues: vb.sorted()))
                }
            }
            out.append(GroupDiff(key: key, inA: true, inB: true, changedOffsets: changed))
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
    /// Each truth point is matched to the nearest record by `ts_ms` within `maxDtMs`, `fieldName` is
    /// read from that record's decoded dict, and the paired values are scored: mean-absolute-error,
    /// bias (mean signed error), and Pearson r. This is the instrument-first check that lets a
    /// candidate PPG→HRV / SpO₂ mapping be *validated*, not eyeballed — and it's honest about coverage
    /// (`n` is how many points actually matched a decoded record).
    public static func groundTruth(records: [Record], truth: [TruthPoint],
                                   fieldName: String, maxDtMs: Int = 60_000) -> Score {
        let stamped = records.filter { $0.tsMs != nil }
        var residuals: [Residual] = []
        for t in truth.sorted(by: { $0.tsMs < $1.tsMs }) {
            var best: Record?; var bestDt = Int.max
            for r in stamped {
                let dt = abs(r.tsMs! - t.tsMs)
                if dt < bestDt { bestDt = dt; best = r }
            }
            guard let match = best, bestDt <= maxDtMs else {
                residuals.append(Residual(tsMs: t.tsMs, truth: t.value, decoded: nil, dtMs: bestDt))
                continue
            }
            let decoded = match.frame.parsed[fieldName]?.doubleValue
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
