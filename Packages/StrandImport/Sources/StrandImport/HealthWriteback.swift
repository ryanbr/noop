import Foundation

/// Pure mapping from NOOP's persisted sleep-stage JSON to the interval list the iOS HealthKit
/// write-back turns into `sleepAnalysis` category samples. Lives here (not in the app target) so
/// the parsing/clamping logic is covered by `swift test` — HealthKit itself can't be unit-tested.
public enum HealthWriteback {

    /// A HealthKit-agnostic sleep stage. The bridge maps these onto `HKCategoryValueSleepAnalysis`
    /// (`awake → .awake`, `light → .asleepCore`, `deep → .asleepDeep`, `rem → .asleepREM`,
    /// `unspecified → .asleepUnspecified` — the honest block for a fragment whose `stagesJSON`
    /// carries no timing).
    public enum StageKind: String, Equatable {
        case awake, light, deep, rem, unspecified
    }

    public struct StageInterval: Equatable {
        public let start: Int   // unix seconds
        public let end: Int     // unix seconds, > start
        public let kind: StageKind
        public init(start: Int, end: Int, kind: StageKind) {
            self.start = start; self.end = end; self.kind = kind
        }
    }

    /// Decode a session's `stagesJSON` into clamped stage intervals for HealthKit.
    ///
    /// Only the on-device SleepStager segment shape (`[{"start","end","stage"}]`, unix seconds)
    /// carries timing, so only it yields intervals. The two aggregate shapes NOOP has also
    /// persisted (`{"deep":min,…}` and `[{"stage","min"}]` — see `WhoopCsvExporter.stageMinutes`)
    /// have no placement information; fabricating positions for them would write fiction into
    /// Health, so they return `[]` and the caller falls back to one `.asleepUnspecified` block.
    ///
    /// Normalization: the stager labels awake as `"wake"`, importers as `"awake"` — both map to
    /// `.awake`. Unknown labels are dropped. Segments are clamped to `[sessionStart, sessionEnd]`
    /// and zero/negative-length segments (before or after clamping) are dropped.
    public static func stageIntervals(stagesJSON: String?,
                                      sessionStart: Int,
                                      sessionEnd: Int) -> [StageInterval] {
        guard sessionEnd > sessionStart,
              let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let segments = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        var out: [StageInterval] = []
        for seg in segments {
            // Aggregate shape ([{"stage","min"}]) has no start/end — bail to the no-timing path
            // for the WHOLE session rather than emit a partial mix.
            guard let rawStart = intValue(seg["start"]), let rawEnd = intValue(seg["end"]) else {
                return []
            }
            guard let stage = (seg["stage"] as? String)?.lowercased() else { continue }
            let kind: StageKind?
            switch stage {
            case "wake", "awake": kind = .awake
            case "light":         kind = .light
            case "deep":          kind = .deep
            case "rem":           kind = .rem
            default:              kind = nil
            }
            guard let kind else { continue }
            let start = max(rawStart, sessionStart)
            let end = min(rawEnd, sessionEnd)
            guard end > start else { continue }
            out.append(StageInterval(start: start, end: end, kind: kind))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// JSON numbers arrive as Int, Double, or NSNumber depending on the writer; accept all.
    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        default: return nil
        }
    }

    // MARK: - Merged nights (#364)

    /// One stored sleep fragment, as the write-back sees it: the immutable detected key (`startTs`),
    /// the edited onset when present (`effectiveStartTs` — drives the span, never the key, #318),
    /// the wake, and the persisted stage JSON.
    public struct SleepFragment: Equatable {
        public let startTs: Int
        public let effectiveStartTs: Int
        public let endTs: Int
        public let stagesJSON: String?
        public init(startTs: Int, effectiveStartTs: Int, endTs: Int, stagesJSON: String?) {
            self.startTs = startTs; self.effectiveStartTs = effectiveStartTs
            self.endTs = endTs; self.stagesJSON = stagesJSON
        }
    }

    /// One bridged night, folded for the write-back: the `.inBed` span, the merged stage timeline,
    /// the representative dedup key, and the COMPLETE per-fragment key set for deletion.
    public struct MergedSleepEntry: Equatable {
        /// The group's dedup key: the EARLIEST fragment's immutable detected `startTs` (a user edit
        /// moves the span via `effectiveStartTs`, never this key, so the entry keeps its identity).
        public let keyStartTs: Int
        /// Earliest edited onset → latest wake across the group: the one `.inBed` span.
        public let spanStart: Int
        public let spanEnd: Int
        /// The fragments' stage intervals in time order — a fragment with no decodable timing
        /// contributes one honest `.unspecified` block over its own window — with every
        /// inter-fragment seam as an explicit `.awake` interval.
        public let intervals: [StageInterval]
        /// EVERY fragment's immutable `startTs`, ascending. The delete predicate must carry all of
        /// them: a night previously exported as two entries would otherwise orphan the absorbed
        /// fragment's old entry when it becomes one.
        public let allKeyStartTs: [Int]
        public init(keyStartTs: Int, spanStart: Int, spanEnd: Int,
                    intervals: [StageInterval], allKeyStartTs: [Int]) {
            self.keyStartTs = keyStartTs; self.spanStart = spanStart; self.spanEnd = spanEnd
            self.intervals = intervals; self.allKeyStartTs = allKeyStartTs
        }
    }

    /// Fold bridged night groups (#364) into write-back entries — one `.inBed` span per night with
    /// the mid-night wake seams as explicit `.awake` intervals, matching what the daily totals
    /// already score (#561/#777) and what Oura / Apple Watch write into Health. `groups` comes from
    /// `SleepStageTotals.bridgedNightGroups` (this package deliberately doesn't depend on the
    /// analytics package, so the grouping happens in the caller). Fragments are re-sorted by
    /// effective onset defensively; a zero/negative-length fragment contributes no interval but
    /// keeps its key in the delete set; a group with no positive span is skipped entirely.
    public static func mergedSleepPlan(groups: [[SleepFragment]]) -> [MergedSleepEntry] {
        var out: [MergedSleepEntry] = []
        for group in groups where !group.isEmpty {
            let frags = group.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
            var intervals: [StageInterval] = []
            var prevEnd: Int? = nil
            var spanStart: Int? = nil
            for f in frags {
                guard f.endTs > f.effectiveStartTs else { continue }
                if spanStart == nil { spanStart = f.effectiveStartTs }
                if let p = prevEnd, f.effectiveStartTs > p {
                    intervals.append(StageInterval(start: p, end: f.effectiveStartTs, kind: .awake))
                }
                let stages = stageIntervals(stagesJSON: f.stagesJSON,
                                            sessionStart: f.effectiveStartTs, sessionEnd: f.endTs)
                if stages.isEmpty {
                    intervals.append(StageInterval(start: f.effectiveStartTs, end: f.endTs,
                                                   kind: .unspecified))
                } else {
                    intervals.append(contentsOf: stages)
                }
                prevEnd = max(prevEnd ?? f.endTs, f.endTs)
            }
            guard let start = spanStart, let end = prevEnd, end > start else { continue }
            out.append(MergedSleepEntry(
                keyStartTs: frags.map(\.startTs).min() ?? 0,
                spanStart: start,
                spanEnd: end,
                intervals: intervals,
                allKeyStartTs: frags.map(\.startTs).sorted()))
        }
        return out
    }

    // MARK: - Apple Health external UUID keys (#1503)

    /// The deterministic `HKMetadataKeyExternalUUID` for a NOOP-written Apple Health record.
    ///
    /// The key is a natural key — `noop:<kind>:<identity>` — with NO device-id segment. The previous
    /// scheme embedded the active strap id (`noop:<deviceId>:<kind>:<identity>`), which is NOT durable:
    /// a re-pair or serial-based identification changes it, and every record written under the old id
    /// becomes unreachable to the delete-then-write reconciliation (the delete predicate is built from
    /// the id that is active NOW). The stranded records stay in Apple Health permanently as duplicates.
    ///
    /// Dropping the id segment matches the Android twin (`HealthConnectWriter.clientRecordId` carries
    /// no device id — `noop-workout-<startTs>`) and makes the key mean what it is: a natural key over
    /// the record's own identity, stable across strap lifecycle changes.
    ///
    /// `kind` is the metric's `HKQuantityTypeIdentifier.rawValue` for vitals, `"sleep"` for sleep
    /// sessions, or `"workout"` for workouts. `identity` is the day key ("yyyy-MM-dd") for vitals or
    /// the unix-second start timestamp for sleep/workout.
    public static func appleHealthExternalUUID(kind: String, identity: String) -> String {
        "noop:\(kind):\(identity)"
    }

    /// The vitals key: `noop:<metricId>:<day>`.
    public static func appleHealthVitalKey(metricId: String, day: String) -> String {
        appleHealthExternalUUID(kind: metricId, identity: day)
    }

    /// The sleep key: `noop:sleep:<startTs>`.
    public static func appleHealthSleepKey(startTs: Int) -> String {
        appleHealthExternalUUID(kind: "sleep", identity: "\(startTs)")
    }

    /// The workout key: `noop:workout:<startTs>`.
    public static func appleHealthWorkoutKey(startTs: Int) -> String {
        appleHealthExternalUUID(kind: "workout", identity: "\(startTs)")
    }
}
