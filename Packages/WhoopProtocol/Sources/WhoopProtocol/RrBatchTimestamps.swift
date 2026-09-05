import Foundation

/// Spread a frame's R-R array across the time it actually describes (#1118).
///
/// Every ingest path stamped EVERY interval in a frame's `rr_intervals` array with that frame's single
/// timestamp:
///
///     for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
///
/// A frame carrying two ~740 ms intervals therefore deposited ~1.5 seconds of beat-time onto one second
/// of wall clock, and `rrCoverage` - which is exactly that ratio - read 1.5. A field capture measured
/// `beatsPerSec=2.15` with `covExact=1.80` on a WHOOP 4.0 whose beats were entirely genuine.
///
/// ## This is not de-duplication
///
/// The beats are real and distinct; only their timestamps were collapsed. That is why removing exact
/// `(ts,rrMs)` duplicates freed 0.3% of rows and left coverage at 1.80, and why a 40 ms same-second
/// collapse reached 1.09-1.43 only by deleting real beats (beat accuracy fell to 0.57-0.66). There was
/// never anything to remove.
///
/// ## The convention, and why the risk in it is small
///
/// The array is oldest-first and the MOST RECENT interval ends at the frame timestamp, following the
/// Heart Rate Service shape these frames mirror (`rr_count` then the values, in 1/1024 s). So interval
/// `i` is placed at `frameTs` minus the intervals that follow it.
///
/// If that is backwards and `frameTs` marks the START of the batch, every beat shifts by at most one
/// batch width - under two seconds. That barely matters: RMSSD and SDNN are built from successive
/// DIFFERENCES between interval values, which this does not touch, and coverage depends on the span the
/// beats occupy rather than where the span sits. A whole-batch offset changes neither. What it could
/// nudge is which sleep stage a beat at a stage boundary falls in, which is noise at this scale.
///
/// ## Safe where there is nothing to spread
///
/// A single-interval array returns unchanged, so a strap whose frames arrive at about its beat rate -
/// the 5/MG, whose nights already read coverage ~1.0 - is byte-identical through this. Only a batching
/// frame moves, which is the only case that was ever wrong.
public enum RrBatchTimestamps {

    /// The frame's intervals with a timestamp each, oldest first.
    ///
    /// Timestamps are whole seconds, so a sub-second step sometimes lands two beats in one second and
    /// sometimes in adjacent ones. That is fine and is not an approximation worth avoiding: coverage is
    /// measured across a night, where the spread's total is what counts, not any single pair.
    public static func spread(frameTs: Int, rrMs: [Int]) -> [(ts: Int, rrMs: Int)] {
        guard rrMs.count > 1 else { return rrMs.map { (ts: frameTs, rrMs: $0) } }
        var out: [(ts: Int, rrMs: Int)] = []
        out.reserveCapacity(rrMs.count)
        // Walk backwards accumulating the intervals AFTER each one: the last ends at `frameTs`, the one
        // before it a beat earlier, and so on.
        var msAfter = 0
        for value in rrMs.reversed() {
            out.append((ts: frameTs - Int((Double(msAfter) / 1000.0).rounded()), rrMs: value))
            msAfter += max(0, value)
        }
        return out.reversed()
    }
}
