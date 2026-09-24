import SwiftUI
import StrandDesign

/// The one way to consume live R-R packets: observe `rrSeq`, deliver `rr`. Watching the `rr` value
/// instead silently drops a second identical consecutive packet — lost real beats for anything that
/// accumulates successive differences (spot HRV, Breathe's session RMSSD). Filters empty packets.
/// Removes the value-equality drop, not run-loop coalescing. Twin of Kotlin `Flow<LiveState>.rrPackets()`.
extension View {
    func onRRPackets(_ live: LiveState, perform ingest: @escaping ([Int]) -> Void) -> some View {
        onChangeCompat(of: live.rrSeq) { _ in
            if !live.rr.isEmpty { ingest(live.rr) }
        }
    }
}

/// The same rule for a consumer that is not a view: take a live R-R packet once, keyed on `rrSeq`.
///
/// A `@Published` sink runs inside `willSet`, before the new value lands, so a handler that reads `live` from
/// a sink sees the packet the strap sent BEFORE the one being written. `setRRIntervals` moves `rr` and `rrSeq`
/// together, so `live.rr` always belongs to `live.rrSeq`, whichever sink is running: asking this cursor whether
/// that sequence is new takes every packet exactly once, however many sinks reach the handler for it.
struct RRPacketCursor {
    private(set) var lastSeq = 0

    /// True the first time `seq` is offered, and false for any repeat of it.
    mutating func isNew(_ seq: Int) -> Bool {
        guard seq != lastSeq else { return false }
        lastSeq = seq
        return true
    }
}
