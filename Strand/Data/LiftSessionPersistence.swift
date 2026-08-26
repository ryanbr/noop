import Foundation
import WhoopStore

// Crash-safety for an in-flight gym session.
//
// A session is written to UserDefaults on every tap and rehydrated on launch, so a crash, a phone
// call, a flat battery or simply swiping the app away mid-workout costs nothing. This mirrors
// `ActiveWorkoutPersistence` exactly — a small `Codable` snapshot, unix-second anchors, and an
// encode/decode pair that is pure (no UserDefaults dependency of its own) so the round-trip is
// testable without touching the defaults database.
//
// Unix seconds rather than `Date` for the same reason the store uses them: an absolute instant
// survives suspension, timezone changes and a relaunch, and it is the only anchor that keeps a rest
// countdown honest.

enum LiftSessionPersistence {

    /// The durable shape of an in-flight session — the minimum needed to rebuild the engine and still
    /// finish and save the session after a relaunch.
    struct Snapshot: Codable, Equatable {
        var startSec: Int
        var programId: String?
        var programName: String?
        /// The plan, flattened at start. Stored rather than re-read from the program so that editing
        /// or deleting the program mid-session cannot change what is being run.
        var plan: [PlanItem]
        var stage: StageBox
        var sets: [RecordedSet]
        var stageStartedAt: Int

        struct PlanItem: Codable, Equatable {
            var exercise: String
            var primaryMuscle: String?
            var secondaryMuscles: [String]
            var targetSets: Int
            var restSec: Int
            var targetRepsLow: Int?
            var targetRepsHigh: Int?
            var targetRpe: Double?
            var note: String?
        }

        /// The stage as a flat, forward-compatible record rather than an encoded enum: a persisted
        /// enum with associated values is a migration hazard the moment a case is added, and this
        /// shape decodes to "warm-up" rather than to garbage if it is ever read by an older build.
        struct StageBox: Codable, Equatable {
            var kind: String        // warmup | working | resting | cooldown | finished
            var item: Int?
            var set: Int?
            var endsAt: Int?
        }

        struct RecordedSet: Codable, Equatable {
            var exerciseIndex: Int
            var setIndex: Int
            var weightKg: Double?
            var reps: Int?
            var rpe: Double?
            var isWarmup: Bool
            var startTs: Int
            var endTs: Int
            var restSec: Int?
        }
    }

    /// The single UserDefaults key (JSON-encoded `Snapshot`), namespaced like `noop.activeWorkout`.
    static let defaultsKey = "noop.activeLiftSession"

    // MARK: - Codec

    static func encode(_ snapshot: Snapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Decode a snapshot, bound-checking the untrusted persisted values. Returns nil for
    /// nil/garbage/empty input or an implausible start time, so a corrupt write is treated as "no
    /// session in flight" rather than reviving a broken screen the user cannot get out of.
    static func decode(_ data: Data?) -> Snapshot? {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode(Snapshot.self, from: data),
              raw.startSec > 1_000_000_000,                       // after 2001; not a zero/garbage anchor
              raw.startSec < Int(Date().timeIntervalSince1970) + 86_400,
              !raw.plan.isEmpty
        else { return nil }
        return raw
    }

    // MARK: - UserDefaults

    static func store(_ snapshot: Snapshot?, into d: UserDefaults = .standard) {
        guard let snapshot, let data = encode(snapshot) else {
            d.removeObject(forKey: defaultsKey)
            return
        }
        d.set(data, forKey: defaultsKey)
    }

    static func load(from d: UserDefaults = .standard) -> Snapshot? {
        decode(d.data(forKey: defaultsKey))
    }

    static func clear(_ d: UserDefaults = .standard) {
        d.removeObject(forKey: defaultsKey)
    }

    // MARK: - Engine bridge

    static func snapshot(engine: LiftSessionEngine,
                         programId: String?,
                         programName: String?) -> Snapshot {
        Snapshot(
            startSec: engine.startTs,
            programId: programId,
            programName: programName,
            plan: engine.plan.map {
                Snapshot.PlanItem(exercise: $0.exercise,
                                  primaryMuscle: $0.primaryMuscle?.rawValue,
                                  secondaryMuscles: $0.secondaryMuscles.map(\.rawValue),
                                  targetSets: $0.targetSets,
                                  restSec: $0.restSec,
                                  targetRepsLow: $0.targetRepsLow,
                                  targetRepsHigh: $0.targetRepsHigh,
                                  targetRpe: $0.targetRpe,
                                  note: $0.note)
            },
            stage: box(engine.stage),
            sets: engine.sets.map {
                Snapshot.RecordedSet(exerciseIndex: $0.exerciseIndex, setIndex: $0.setIndex,
                                     weightKg: $0.weightKg, reps: $0.reps, rpe: $0.rpe,
                                     isWarmup: $0.isWarmup, startTs: $0.startTs, endTs: $0.endTs,
                                     restSec: $0.restSec)
            },
            stageStartedAt: engine.stageStartedAt)
    }

    /// Rebuild an engine from a snapshot. Unknown muscle tokens are dropped rather than failing the
    /// read, matching `LiftMuscle.decodeList`: a snapshot written by a newer build must not strand a
    /// session in an older one.
    static func engine(from s: Snapshot) -> LiftSessionEngine {
        let plan = s.plan.map {
            LiftPlanItem(exercise: $0.exercise,
                         primaryMuscle: $0.primaryMuscle.flatMap(LiftMuscle.init(rawValue:)),
                         secondaryMuscles: $0.secondaryMuscles.compactMap(LiftMuscle.init(rawValue:)),
                         targetSets: $0.targetSets,
                         restSec: $0.restSec,
                         targetRepsLow: $0.targetRepsLow,
                         targetRepsHigh: $0.targetRepsHigh,
                         targetRpe: $0.targetRpe,
                         note: $0.note)
        }
        let sets = s.sets.map {
            LiftRecordedSet(exerciseIndex: $0.exerciseIndex, setIndex: $0.setIndex,
                            weightKg: $0.weightKg, reps: $0.reps, rpe: $0.rpe,
                            isWarmup: $0.isWarmup, startTs: $0.startTs, endTs: $0.endTs,
                            restSec: $0.restSec)
        }
        return LiftSessionEngine(restoring: plan, startTs: s.startSec,
                                 stage: unbox(s.stage), sets: sets, stageStartedAt: s.stageStartedAt)
    }

    private static func box(_ stage: LiftSessionEngine.Stage) -> Snapshot.StageBox {
        switch stage {
        case .warmup:  return .init(kind: "warmup", item: nil, set: nil, endsAt: nil)
        case .working(let i, let s): return .init(kind: "working", item: i, set: s, endsAt: nil)
        case .resting(let i, let s, let e): return .init(kind: "resting", item: i, set: s, endsAt: e)
        case .cooldown: return .init(kind: "cooldown", item: nil, set: nil, endsAt: nil)
        case .finished: return .init(kind: "finished", item: nil, set: nil, endsAt: nil)
        }
    }

    /// Anything unrecognised (or a `working`/`resting` box missing its indices) falls back to the
    /// warm-up: the session is still recoverable and still saveable, which beats refusing to load.
    private static func unbox(_ box: Snapshot.StageBox) -> LiftSessionEngine.Stage {
        switch box.kind {
        case "working":
            guard let i = box.item, let s = box.set else { return .warmup }
            return .working(item: i, set: s)
        case "resting":
            guard let i = box.item, let s = box.set, let e = box.endsAt else { return .warmup }
            return .resting(item: i, set: s, endsAt: e)
        case "cooldown": return .cooldown
        case "finished": return .finished
        default: return .warmup
        }
    }
}
