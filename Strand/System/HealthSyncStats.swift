import Foundation

/// #1578: what the HealthKit observer path actually cost this session.
///
/// The battery question that prompted this — "is Apple Health sync draining the phone?" — could not be
/// answered from an exported log, because nothing on that path measured anything. The optimisation that
/// came with it (coalescing observer wakes) is itself unmeasured for the same reason, so it cannot be
/// evaluated after the fact either. This is the missing half: counts and a duration, in the header the
/// reporter already sends.
///
/// Deliberately counts WAKES separately from SYNCS. Coalescing reduces the work per wake, not the number
/// of wakes — iOS still resumes the process for every observer notification, and if that resume is the
/// dominant cost then this ratio is what says so. A log showing many wakes and few syncs means the
/// coalescing is working AND that the remaining cost is the wake itself, which would call for a different
/// fix (fewer observers, or dropping background delivery for the chatty types) rather than more of this
/// one.
///
/// In `Strand/` rather than `StrandiOS/` on purpose: this is shared-target, so `StrandTests` can reach it.
/// A type placed beside `HealthKitBridge` would be testable by nothing.
///
/// Counts and milliseconds only — no sample values, no timestamps, same privacy class as the rest of the
/// header. Process-lifetime, never persisted.
@MainActor
enum HealthSyncStats {

    /// Observer notifications handled, whether or not they led to a sync.
    private(set) static var wakes = 0
    /// Wakes that ran a full sync.
    private(set) static var syncs = 0
    /// Wakes that stood down because a recent sync already covered their window.
    private(set) static var coalesced = 0
    /// Wakes that found no new samples at all (a spurious notification).
    private(set) static var emptyWakes = 0
    /// Cumulative wall time inside `sync()`, milliseconds.
    private(set) static var syncMillis = 0

    static func recordWake() { wakes += 1 }
    static func recordEmptyWake() { emptyWakes += 1 }
    static func recordCoalesced() { coalesced += 1 }
    static func recordSync(millis: Int) { syncs += 1; syncMillis += max(0, millis) }

    /// Test seam — the counters are process-lifetime, so a suite needs a way back to zero.
    static func reset() { wakes = 0; syncs = 0; coalesced = 0; emptyWakes = 0; syncMillis = 0 }

    /// One header line, or nothing at all when the observer path never ran this session.
    ///
    /// Silent-when-unused matters: most logs come from people whose Health sync is off or unauthorized,
    /// and a line of zeros in every one of those would be noise that trains readers to skip the block.
    static func summaryLines() -> [String] {
        guard wakes > 0 else { return [] }
        let avg = syncs > 0 ? syncMillis / syncs : 0
        return ["Health sync: wakes=\(wakes) synced=\(syncs) coalesced=\(coalesced) "
                + "empty=\(emptyWakes) avgSyncMs=\(avg)"]
    }
}
