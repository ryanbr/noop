import Foundation

/// PRE-STORAGE census of a decoded R-R batch (#1008/#1118 instrumentation).
///
/// Every existing R-R number — `rrCoverage`, `collapsedCoverage`, the `hrv diag` line — is measured
/// AFTER the rows are stored, so it cannot distinguish the two candidate causes of the WHOOP 4.0
/// over-count:
///
///   * the strap/decoder EMITS more beat-time than elapsed (a decode or protocol reading), or
///   * the same beats are STORED twice because two ingest passes both wrote them.
///
/// `ratio` settles it. It is Σ(rrMs) over the batch's own wall span, computed on the decoded batch
/// before a single row reaches SQLite: if it already sits near the ~1.7 the nightly diag reports, no
/// storage-side de-dup can be the fix, and the defect is upstream of the database. If it sits near 1.0
/// while the stored night still reads 1.7, the duplication is in ingest and the de-dup work is aimed
/// correctly. Nothing in the shipped path reads any of this — instrumentation only.
///
/// `perSecond` characterises the shape rather than just the size: at ~69 bpm a one-second record should
/// carry ONE interval (occasionally two, when two beats end inside the same second), so a fat 3-4 tail is
/// what a rolling/overlapping strap buffer would look like.
///
/// There is deliberately NO cross-second repeat counter here. Counting an interval that reappears
/// verbatim one second later cannot distinguish a re-sent beat from a STEADY HEART — at rest,
/// consecutive real intervals are near-identical by definition, so such a counter reads high on
/// perfectly clean data and answers nothing. (Written, tested, and removed when the clean-stream vector
/// below made it report 9 "repeats" out of 10 honest beats.) `ratio` carries the signal instead: it is
/// bounded by physics, not by resemblance.
///
/// Pure and framework-free. Byte-parity twin of Kotlin `RrEmissionStats`.
public enum RrEmissionStats {

    public struct Result: Equatable, Sendable {
        /// Distinct timestamps carrying at least one interval (≈ records that reported R-R).
        public let secondsWithRr: Int
        /// Total intervals offered by the decoder, before any storage de-dup.
        public let intervals: Int
        /// Σ of every interval, in milliseconds.
        public let sumRrMs: Int
        /// Wall span the batch covers, inclusive, in seconds. 0 when fewer than one timestamp.
        public let spanSec: Int
        /// `sumRrMs / 1000 / spanSec` — beat-time per second of wall time. >1 means the batch carries
        /// more beat-time than the clock allows, which is physically impossible and therefore an
        /// emission or decode defect rather than a heart.
        public let ratio: Double
        /// Histogram of intervals-per-second: index 0 = seconds with exactly 1, 1 = exactly 2,
        /// 2 = exactly 3, 3 = 4 or more.
        public let perSecond: [Int]
        /// Histogram of the gap between consecutive records THAT CARRIED R-R, in seconds: index 0 = 1 s,
        /// … index 6 = 7 s, index 7 = 8 s or more. Not the strap's raw record cadence — a record banking
        /// no interval is invisible here — but that is exactly the right set, because `ratioRep` divides
        /// by the same one: healthy `ratioRep` ≈ the mean of these gaps, whose mode this reports. A strap
        /// banking R-R every 5 s reads `ratioRep` ≈ 5 while perfectly healthy, so reading it against 1.0
        /// would invent a defect (#1451). Ties resolve to the smaller gap on both platforms.
        public let gapHist: [Int]
        /// Histogram of per-record FILL: that record's Σ(rrMs) over its own slot (the gap to the next
        /// record). Index 0 = ≤1.0, 1 = ≤1.5, 2 = ≤2.0, 3 = >2.0. This is the measurement a timeline fix
        /// needs and no aggregate can supply: whether ONE record carries more beat-time than the interval
        /// it covers. Fill ~1.0 means records tile the timeline and each interval can be placed at its own
        /// reconstructed beat time; a fat tail means the records themselves overflow and no placement
        /// scheme built on the record timestamp can be correct. The final record has no successor and is
        /// excluded. Known bias: the slot is the gap to the next R-R-carrying record, so if a strap
        /// interleaves records without intervals the slot spans more than one record period and fill reads
        /// LOW. It can therefore understate overflow, never manufacture it.
        public let fill: [Int]

        public init(secondsWithRr: Int, intervals: Int, sumRrMs: Int, spanSec: Int,
                    ratio: Double, perSecond: [Int],
                    gapHist: [Int] = [0, 0, 0, 0, 0, 0, 0, 0], fill: [Int] = [0, 0, 0, 0]) {
            self.secondsWithRr = secondsWithRr
            self.intervals = intervals
            self.sumRrMs = sumRrMs
            self.spanSec = spanSec
            self.ratio = ratio
            self.perSecond = perSecond
            self.gapHist = gapHist
            self.fill = fill
        }

        /// The modal record gap in seconds — the mode of `gapHist`, with 8 meaning "8 or more".
        /// 0 when the batch held fewer than two records. This is the healthy baseline for `ratioRep`.
        public var modalGapSec: Int {
            guard let m = gapHist.max(), m > 0, let i = gapHist.firstIndex(of: m) else { return 0 }
            return i + 1
        }
    }

    /// Census a decoded batch. `rr` is the decoder's output order; nothing is mutated or sorted in place.
    public static func compute(_ rr: [(ts: Int, rrMs: Int)]) -> Result {
        guard !rr.isEmpty else {
            return Result(secondsWithRr: 0, intervals: 0, sumRrMs: 0, spanSec: 0,
                          ratio: 0, perSecond: [0, 0, 0, 0])
        }
        var bySecond: [Int: [Int]] = [:]
        var sum = 0
        var minTs = Int.max
        var maxTs = Int.min
        for r in rr {
            bySecond[r.ts, default: []].append(r.rrMs)
            sum += r.rrMs
            if r.ts < minTs { minTs = r.ts }
            if r.ts > maxTs { maxTs = r.ts }
        }
        // Inclusive span: a single-second batch spans 1 s, not 0, so the ratio stays finite.
        let span = maxTs - minTs + 1
        var hist = [0, 0, 0, 0]
        for (_, vals) in bySecond {
            let i = min(vals.count, 4) - 1
            if i >= 0 { hist[i] += 1 }
        }
        // Per-record cadence and fill (#1451). A record's SLOT is the gap to the next record, so the last
        // record is excluded — it has no successor to bound it.
        let stamps = bySecond.keys.sorted()
        var gapHist = [0, 0, 0, 0, 0, 0, 0, 0]
        var fill = [0, 0, 0, 0]
        if stamps.count >= 2 {
            for i in 0..<(stamps.count - 1) {
                let gap = stamps[i + 1] - stamps[i]
                guard gap >= 1 else { continue }
                gapHist[min(gap, 8) - 1] += 1
                let recSum = (bySecond[stamps[i]] ?? []).reduce(0, +)
                let f = Double(recSum) / 1000.0 / Double(gap)
                fill[f <= 1.0 ? 0 : (f <= 1.5 ? 1 : (f <= 2.0 ? 2 : 3))] += 1
            }
        }
        let ratio = span > 0 ? Double(sum) / 1000.0 / Double(span) : 0
        return Result(secondsWithRr: bySecond.count, intervals: rr.count, sumRrMs: sum,
                      spanSec: span, ratio: ratio, perSecond: hist, gapHist: gapHist, fill: fill)
    }

    /// One compact log line. `offered`/`inserted` come from the caller: `inserted` is what the store
    /// actually wrote after its `ON CONFLICT` key, so `offered - inserted` is how much the primary key
    /// already absorbs — the third number needed to tell emission from ingest.
    ///
    /// TWO ratios are printed because `ratio` alone can be read the wrong way round on a whole SESSION.
    /// A session that drains a gap — the strap off the wrist, or on the charger — spans wall time that
    /// carries no beats at all, which inflates the denominator and pulls `ratio` DOWN. That is the
    /// dangerous direction of error here: a diluted 0.9 reads as "emission is fine" on the one number
    /// this instrumentation exists to answer. `ratioRep` divides by the seconds that actually REPORTED
    /// R-R instead of by the wall span, so it is immune to gaps; the two agreeing means the batch is
    /// gapless, and `ratioRep` is the one to trust when they disagree. (`ratioRep`'s denominator can
    /// double-count at most one second per chunk boundary when a session's counts are summed, which is
    /// negligible against thousands of seconds — and errs the same safe way, low.)
    public static func logLine(path: String, offered: Int, inserted: Int, _ r: Result) -> String {
        let ratio = String(format: "%.2f", r.ratio)
        let rep = r.secondsWithRr > 0 ? Double(r.sumRrMs) / 1000.0 / Double(r.secondsWithRr) : 0
        let h = r.perSecond
        return "rr emit path=\(path) offered=\(offered) inserted=\(inserted) secs=\(r.secondsWithRr) "
            + "sumRr=\(r.sumRrMs / 1000)s span=\(r.spanSec)s ratio=\(ratio) "
            + "ratioRep=\(String(format: "%.2f", rep)) "
            + "perSec[1/2/3/4+]=\(h[0])/\(h[1])/\(h[2])/\(h[3]) "
            + "modalGap=\(r.modalGapSec)s "
            + "fill[<=1/<=1.5/<=2/>2]=\(r.fill[0])/\(r.fill[1])/\(r.fill[2])/\(r.fill[3])"
    }
}
