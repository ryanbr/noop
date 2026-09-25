import Foundation

/// Beats a redrain stored a second time, recognised by the record they came in rather than by their
/// timestamps (#2456).
///
/// A ring record is served again whenever history is refetched: after a link drops mid-drain, and also
/// after a night has already drained, which is the case a resume cursor cannot prevent. Each connection
/// adopts its own SyncTime anchor, so the second copy resolves to a wall-clock second one or two off the
/// first and misses `rrInterval`'s `(deviceId, ts, rrMs, seq)` key instead of colliding with it. Both
/// copies are then stored, the night's R-R coverage rises above 1, and its HRV is refused as an
/// over-count. One reported night went from coverage 0.99 with HRV shown to 1.22 with the night's HRV
/// gone, retroactively, after a redrain added 6,466 channel-3 beats of which 5,471 were an exact copy
/// stamped one second later.
///
/// What identifies a copy is the RECORD, not the beat. A banked 0x60 record stamps all of its intervals
/// on one timestamp, so a re-served record reappears as the same ordered run of `rrMs` values on the
/// same channel a second or two later. Single beats are NOT enough to go on: equal successive beats are
/// physiological and are deliberately kept (#163), and on a clean night 2.5% of beats already have an
/// equal neighbour one second away. A whole ordered run repeating is not a coincidence at that rate.
///
/// Collapsing on read rather than deleting on write is deliberate: it needs no migration, it costs
/// nothing if the ring never re-serves, and it repairs nights that were already double-stored, which a
/// write-side key can never do. It does not reclaim the disk those rows occupy. The structural fix is
/// still to dedup on a clock the ring owns; this makes the nights readable in the meantime.
public enum OuraRedrainCollapse {

    /// Beats within `withinSeconds` that repeat an earlier run of at least `minimumRun` beats, dropped.
    ///
    /// Order is preserved, only Oura channels are considered, and a run is compared against the last run
    /// KEPT with that signature, so a record served three times collapses to one rather than to two.
    public static func withoutRedrainedRuns(_ beats: [RRInterval],
                                            withinSeconds: Int = 2,
                                            minimumRun: Int = 3) -> [RRInterval] {
        guard minimumRun > 1, withinSeconds > 0, beats.count > minimumRun else { return beats }

        // (channel, ordered rrMs) -> the timestamp of the last run kept with that signature.
        var lastKept: [String: Int] = [:]
        var dropped = Set<Int>()   // indices into `beats`

        var index = 0
        while index < beats.count {
            let ts = beats[index].ts
            var end = index
            while end < beats.count, beats[end].ts == ts { end += 1 }

            // One timestamp can carry runs from more than one channel; each is its own record.
            var byChannel: [Int: [Int]] = [:]
            for i in index..<end {
                guard let channel = beats[i].srcChannel, channel.isOura else { continue }
                byChannel[channel.rawValue, default: []].append(i)
            }

            for (channel, indices) in byChannel where indices.count >= minimumRun {
                let signature = "\(channel):" + indices.map { String(beats[$0].rrMs) }.joined(separator: ",")
                if let previous = lastKept[signature], ts - previous > 0, ts - previous <= withinSeconds {
                    dropped.formUnion(indices)
                } else {
                    lastKept[signature] = ts
                }
            }
            index = end
        }

        guard !dropped.isEmpty else { return beats }
        return beats.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }
}
