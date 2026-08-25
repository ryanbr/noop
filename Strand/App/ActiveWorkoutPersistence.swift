import Foundation
import WhoopProtocol

/// Durable persistence for an in-flight, manually-started workout (#529).
///
/// A manual workout used to live ONLY in `AppModel.activeWorkout` (in memory), so if iOS killed the app
/// mid-session — a backgrounded phone under memory pressure — the whole session was lost and could never
/// be ended + saved. (Apple has no GPS-route session like Android's `GpsSession`; every manual workout
/// here is the "non-GPS" case, so they all need this.) This is the Apple analogue of Android's
/// `ActiveWorkoutStore`/`ActiveWorkoutPersistence`: a tiny `Codable` snapshot (start time, sport, the
/// accumulated HR samples + running stats) is written to `UserDefaults` on start and on every captured
/// sample, and read back on launch so an interrupted session can still be ended and saved.
///
/// On-device only; mirrors the existing `moments` / `sleepMarks` `UserDefaults` persistence in `AppModel`.
/// The encode/decode is pure (no `UserDefaults` dependency on the codec itself) so the persist/rehydrate
/// round-trip is unit-testable — `store(into:)` / `load(from:)` just thread a `UserDefaults` through it.
enum ActiveWorkoutPersistence {

    /// The durable shape of an in-flight manual workout. A small, self-contained `Codable` value — the
    /// minimum needed to rebuild `AppModel.ActiveWorkout` on relaunch and still End + save it.
    struct Snapshot: Codable, Equatable {
        /// Workout start, as unix seconds (stable across encodings; `AppModel` maps to/from `Date`).
        var startSec: Int
        var sport: String
        var samples: [HRSample]
        var avgHr: Int
        var peakHr: Int
        var liveStrain: Double
        var pausedAtSec: Int? = nil
        var pausedDurationSec: Int? = nil
    }

    /// The single `UserDefaults` key (JSON-encoded `Snapshot`). Namespaced like `moments`/`sleepMarks`.
    static let defaultsKey = "noop.activeWorkout"

    /// Encode a snapshot to JSON `Data`. Returns nil only if encoding somehow fails (never expected for
    /// this all-value shape) so the caller can no-op rather than write garbage.
    static func encode(_ snapshot: Snapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Decode a snapshot from JSON `Data`, bound-checking the untrusted persisted values. Returns nil for
    /// nil/garbage/empty input or an implausible start time, so a corrupt write is treated as "no
    /// in-flight session" rather than reviving a broken card.
    static func decode(_ data: Data?) -> Snapshot? {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        guard raw.startSec > 0 else { return nil }
        // Drop any out-of-range persisted HR samples (a real bpm + a positive ts only) — never trust the
        // blob to be clean. Parity with the Android decoder's 1...300 bpm / ts > 0 gate.
        let samples = raw.samples.filter { $0.ts > 0 && (1...300).contains($0.bpm) }
        return Snapshot(
            startSec: raw.startSec,
            sport: raw.sport,
            samples: samples,
            avgHr: max(0, raw.avgHr),
            peakHr: max(0, raw.peakHr),
            liveStrain: raw.liveStrain.isFinite ? max(0, raw.liveStrain) : 0,
            pausedAtSec: raw.pausedAtSec.flatMap { $0 > 0 ? $0 : nil },
            pausedDurationSec: raw.pausedDurationSec.map { max(0, $0) },
        )
    }

    /// Persist (overwrite) the snapshot. Cheap; called on start + each captured sample.
    static func store(_ snapshot: Snapshot, into defaults: UserDefaults = .standard) {
        guard let data = encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Read back the persisted snapshot, or nil if none is stored (or it was corrupt).
    static func load(from defaults: UserDefaults = .standard) -> Snapshot? {
        decode(defaults.data(forKey: defaultsKey))
    }

    /// Clear the snapshot — called the instant a session ends (saved or discarded).
    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
