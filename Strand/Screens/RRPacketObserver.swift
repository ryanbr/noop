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
