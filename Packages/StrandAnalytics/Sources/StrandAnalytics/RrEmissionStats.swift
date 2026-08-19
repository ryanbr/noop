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

        public init(secondsWithRr: Int, intervals: Int, sumRrMs: Int, spanSec: Int,
                    ratio: Double, perSecond: [Int]) {
            self.secondsWithRr = secondsWithRr
            self.intervals = intervals
            self.sumRrMs = sumRrMs
            self.spanSec = spanSec
            self.ratio = ratio
            self.perSecond = perSecond
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
        let ratio = span > 0 ? Double(sum) / 1000.0 / Double(span) : 0
        return Result(secondsWithRr: bySecond.count, intervals: rr.count, sumRrMs: sum,
                      spanSec: span, ratio: ratio, perSecond: hist)
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
            + "perSec[1/2/3/4+]=\(h[0])/\(h[1])/\(h[2])/\(h[3])"
    }
}
