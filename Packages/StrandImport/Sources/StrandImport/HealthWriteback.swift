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

    /// When each day's nightly vitals are stamped: the midpoint of the LONGEST night whose wake falls on
    /// that day. `dayOf` maps a unix second to the day string the vitals rows are keyed by.
    ///
    /// Inside the night, not on its edge. The values are nightly aggregates, and a reader of Health picks
    /// them by the sleep window they describe — Bevel shows no Recovery when HRV or resting HR is not
    /// captured during the sleep window. A sample stamped exactly at wake sits on that boundary. The
    /// longest night rather than the latest, so a nap after the main sleep does not carry the night's
    /// values out of the night they came from.
    ///
    /// The midpoint of a bridged night can fall in the awake gap between its fragments, or in an awake
    /// segment of one. It is still inside the `.inBed` sample, but a reader that keys off asleep samples
    /// would not see it, so an instant that lands outside every asleep interval moves to the nearest
    /// asleep second. A night whose stages carry no timing has only `.unspecified` asleep intervals and
    /// keeps its midpoint.
    public static func vitalsInstantByDay(_ entries: [MergedSleepEntry],
                                          dayOf: (Int) -> String) -> [String: Int] {
        var longest: [String: MergedSleepEntry] = [:]
        for entry in entries where entry.spanEnd > entry.spanStart {
            let day = dayOf(entry.spanEnd)
            if let current = longest[day],
               current.spanEnd - current.spanStart >= entry.spanEnd - entry.spanStart { continue }
            longest[day] = entry
        }
        return longest.mapValues { entry in
            let mid = entry.spanStart + (entry.spanEnd - entry.spanStart) / 2
            let asleep = entry.intervals.filter { $0.kind != .awake && $0.end > $0.start }
            if asleep.isEmpty || asleep.contains(where: { $0.start <= mid && mid < $0.end }) { return mid }
            // Closest second inside each asleep interval; the nearest wins, the earlier on a tie. A plain loop:
            // the equivalent `map { }.min { }` chain exceeded the type-checker's budget on CI.
            var best = mid
            var bestDistance = Int.max
            for interval in asleep {
                let candidate: Int = min(max(mid, interval.start), interval.end - 1)
                let distance: Int = abs(candidate - mid)
                if distance < bestDistance || (distance == bestDistance && candidate < best) {
                    best = candidate
                    bestDistance = distance
                }
            }
            return best
        }
    }

    /// The vitals key: `noop:<metricId>:<day>`.
    public static func appleHealthVitalKey(metricId: String, day: String) -> String {
        appleHealthExternalUUID(kind: metricId, identity: day)
    }

    /// The sleep key: `noop:sleep:<startTs>`.
    public static func appleHealthSleepKey(startTs: Int) -> String {
        appleHealthExternalUUID(kind: "sleep", identity: "\(startTs)")
    }

    /// The prefix every workout key carries, without the identity.
    ///
    /// Exists so a reader can recognise one of our workouts in Health without reconstructing a key it
    /// does not know the timestamp for: the orphan reconciliation in `HealthKitBridge` matches on this
    /// to tell a workout WE wrote from one another app wrote, before deciding anything about it. Kept
    /// beside the key builder so the two cannot drift. (#2210)
    public static let appleHealthWorkoutKeyPrefix = "noop:workout:"

    /// The workout key: `noop:workout:<startTs>`.
    public static func appleHealthWorkoutKey(startTs: Int) -> String {
        appleHealthExternalUUID(kind: "workout", identity: "\(startTs)")
    }

    /// The beat-to-beat key: `noop:heartbeat:<startTs>`, the night's sleep key identity. Carried by every
    /// heartbeat-series sample written for that night, so the night can be cleared as a unit.
    public static func appleHealthHeartbeatKey(startTs: Int) -> String {
        appleHealthExternalUUID(kind: "heartbeat", identity: "\(startTs)")
    }

    // MARK: - Beat-to-beat (heartbeat series)

    /// One heartbeat-series sample: its start (unix seconds) and each beat's offset from it.
    public struct HeartbeatSeriesChunk: Equatable {
        public struct Beat: Equatable {
            public let offset: Double
            /// The beat does not follow the previous one directly: beats between them were not recorded.
            public let precededByGap: Bool
            public init(offset: Double, precededByGap: Bool) {
                self.offset = offset; self.precededByGap = precededByGap
            }
        }
        public let start: Double
        public let beats: [Beat]
        public init(start: Double, beats: [Beat]) { self.start = start; self.beats = beats }
    }

    /// The longest heartbeat-series sample, in seconds — the 5-minute window NOOP's own SDNN index uses,
    /// short enough for a reader to window its own statistics over.
    public static let heartbeatChunkSeconds: Double = 300

    /// How far a beat may sit from the time its interval predicts before it is read as a gap. The row
    /// stamps are whole seconds, so a continuous train drifts by up to one second against them.
    public static let heartbeatGapToleranceSeconds: Double = 2

    /// Beat times from stored R-R rows (`tsSec` parallel to `rrMs`, ascending). Each beat lands one interval
    /// after the previous; a row whose stamp disagrees with that by more than the tolerance starts again from
    /// its own stamp as a gap. Chunks split at `heartbeatChunkSeconds`. Non-positive intervals are skipped.
    ///
    /// A row stamped at or before the beat already placed is dropped. HealthKit refuses a series whose beats
    /// do not strictly advance ("Heartbeats must be added in order"), and one such row failed the whole
    /// night. It happens when the placed beats run ahead of their whole-second stamps: a phone copy of 15
    /// real nights had 0 to 29 per night, the previous beat sitting 0 to 1.9 s past the late row's stamp.
    /// The beat after a dropped one is still predicted from the last beat placed, so the train carries on.
    public static func heartbeatSeriesPlan(tsSec: [Int], rrMs: [Int]) -> [HeartbeatSeriesChunk] {
        guard tsSec.count == rrMs.count else { return [] }
        var chunks: [HeartbeatSeriesChunk] = []
        var chunkStart = 0.0
        var beats: [HeartbeatSeriesChunk.Beat] = []
        var previous: Double?
        for (ts, rr) in zip(tsSec, rrMs) where rr > 0 {
            let stamp = Double(ts)
            var time = stamp
            var gap = true
            if let previous {
                let predicted = previous + Double(rr) / 1_000
                if abs(predicted - stamp) <= heartbeatGapToleranceSeconds { time = predicted; gap = false }
                else if stamp <= previous { continue }
            }
            if beats.isEmpty || time - chunkStart >= heartbeatChunkSeconds {
                if !beats.isEmpty { chunks.append(.init(start: chunkStart, beats: beats)) }
                chunkStart = time
                beats = []
                gap = false
            }
            beats.append(.init(offset: time - chunkStart, precededByGap: gap))
            previous = time
        }
        if !beats.isEmpty { chunks.append(.init(start: chunkStart, beats: beats)) }
        return chunks
    }

    /// What identifies a night's exported beats: a change in any of these rewrites the night.
    public static func heartbeatFingerprint(tsSec: [Int], rrMs: [Int]) -> String {
        "\(tsSec.count):\(tsSec.first ?? 0):\(tsSec.last ?? 0):\(rrMs.reduce(0, +))"
    }

    /// Which nights' heartbeat series to rewrite or clear. `nights` pairs each night's key with its current
    /// fingerprint, nil when it has no exportable beats; `written` is what was last written per key.
    /// A night is rewritten when its fingerprint moved, cleared when it was written and is no longer
    /// exportable, and left alone otherwise. `kept` is the written record for the nights left alone; a key
    /// outside `nights` has aged out of the window and drops out of the record without touching Health.
    public static func heartbeatSyncPlan(nights: [(key: String, fingerprint: String?)],
                                         written: [String: String])
        -> (rewrite: [(key: String, fingerprint: String)], clear: [String], kept: [String: String]) {
        var rewrite: [(key: String, fingerprint: String)] = []
        var clear: [String] = []
        var kept: [String: String] = [:]
        for night in nights {
            switch (night.fingerprint, written[night.key]) {
            case let (current?, previous) where current != previous:
                rewrite.append((night.key, current))
            case let (current?, _):
                kept[night.key] = current
            case (nil, _?):
                clear.append(night.key)
            case (nil, nil):
                break
            }
        }
        return (rewrite, clear, kept)
    }

    // MARK: - #1503 stranded-records sweep completion tracking
    //
    // The one-off sweep that clears Apple Health records written under the OLD device-id-keyed
    // scheme must be PER-TYPE, not a single boolean. A single flag set unconditionally loses the
    // migration permanently when authorization is partial (sleep granted, workouts declined) or
    // when a `deleteObjects` call fails — both of which read as "already done" and leave the
    // stranded records unreachable forever. Per-type tracking lets an install that could not
    // complete the sweep finish it later, once the missing authorization arrives or the failing
    // delete succeeds on a retry.
    //
    // These pure helpers model the decision so it is unit-testable without HealthKit (HealthKit
    // itself can't run under `swift test`). The app-target migration (`HealthKitBridge`) loads the
    // already-swept set from UserDefaults, computes the types to attempt, attempts each delete, and
    // records only the types whose delete SUCCEEDED back into the swept set.

    /// The type ids that should be attempted this run: authorized for sharing but not yet swept.
    /// A type that was declined (absent from `authorized`) is never attempted and never marked
    /// swept, so a later grant still gets swept. A type whose delete failed (not in `swept`) is
    /// retried on the next write-back run.
    public static func strandedSweepPending(swept: Set<String>, authorized: Set<String>) -> Set<String> {
        authorized.subtracting(swept)
    }

    /// The new swept set after this run: the union of previously swept types and the types whose
    /// delete SUCCEEDED this run. A type whose delete threw (absent from `succeededThisRun`) is NOT
    /// marked swept, so it is retried next run rather than silently abandoned.
    public static func strandedSweepResult(swept: Set<String>, succeededThisRun: Set<String>) -> Set<String> {
        swept.union(succeededThisRun)
    }
}
