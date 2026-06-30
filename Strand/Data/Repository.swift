import Foundation
import Combine
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandDesign   // TrendPoint , the shared chart point type the Deep Timeline series uses

/// Per-day sleep figures the WHOOP export carried verbatim (metricSeries rows written by
/// WhoopImporter under the imported deviceId). SleepView prefers these over its on-device
/// APPROXIMATE recomputations.
struct ImportedSleepFigures: Equatable {
    var performancePct: Double?   // "sleep_performance", 0–100
    var consistencyPct: Double?   // "sleep_consistency", 0–100
    var needMin: Double?          // "sleep_need_min", minutes
    var debtMin: Double?          // "sleep_debt_min", minutes
}

// MARK: - Cross-source resolver model (PR#196 , fresher live charts/metrics)
//
// Product surfaces (Compare, Insights, Stress, Explore, Today) historically read rows under the EXACT
// requested source. That hid freshly-computed and Apple-compatible data that sat under a different
// device id. `Repository.resolvedSeries` resolves a metric over an explicit source PRECEDENCE , imported
// WHOOP wins, NOOP-computed fills the days it doesn't cover, and Apple Health only fills declared-
// compatible vitals on days neither strap source has. These types model that resolution; the exact-source
// reads (`series(key:source:)`) stay available for surfaces that must not mix sources.

/// One day's resolved value plus the source that actually supplied it (so a caption can name it).
struct ResolvedMetricPoint: Equatable, Sendable {
    let day: String
    let value: Double
    let source: String
    let sourceKey: String
}

/// A candidate (source, key) pair the resolver will try, in precedence order.
struct MetricSourceCandidate: Equatable, Hashable, Sendable {
    let source: String
    let key: String
}

/// The full result of resolving one metric: which sources were tried, and the merged per-day points.
struct MetricSeriesResolution: Equatable, Sendable {
    let requestedSource: String
    let candidates: [MetricSourceCandidate]
    let points: [ResolvedMetricPoint]

    /// Plain `(day, value)` rows , the shape the chart/correlation code already consumes.
    var values: [(day: String, value: Double)] { points.map { ($0.day, $0.value) } }

    /// Distinct sources that actually contributed a point, in first-seen order (for a caption).
    var usedSources: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for point in points where !seen.contains(point.source) {
            seen.insert(point.source)
            ordered.append(point.source)
        }
        return ordered
    }
}

/// Source provenance for daily rows before product surfaces merge them. The UI uses this to say
/// where a vital came from without changing the stored data.
enum DailyMetricSource: Equatable {
    case whoopImport
    case noopComputed
    case appleHealth
    case localCache

    var vitalPriority: Int {
        switch self {
        case .whoopImport:  return 0
        case .noopComputed: return 1
        case .appleHealth:  return 2
        case .localCache:   return 3
        }
    }
}

struct SourcedDailyMetric: Equatable {
    let metric: DailyMetric
    let source: DailyMetricSource
}

/// A compact snapshot of how much history each source holds, fed to the Data Sources "Freshness
/// Pipeline" card and the Android equivalent. Counts only , no per-day rows leave the refresh.
struct RepositoryFreshness: Equatable, Sendable {
    var importedDays: Int = 0
    var computedDays: Int = 0
    var appleDays: Int = 0
    var importedSleeps: Int = 0
    var computedSleeps: Int = 0
    var earliestDay: String?
    var latestDay: String?

    static let empty = RepositoryFreshness()

    var hasAnyHistory: Bool { importedDays > 0 || computedDays > 0 || appleDays > 0 }
}

/// Read model over the on-device WhoopStore. Opens its own handle (WAL + busy-timeout makes the
/// two-handle BLEManager+Repository pattern safe) and publishes the dashboard caches the screens bind to.
@MainActor
final class Repository: ObservableObject {
    /// The id of the strap whose recordings this read model surfaces. SEEDED at construction with the
    /// legacy "my-whoop", then RE-POINTED to the device registry's `activeDeviceId` once the store opens
    /// (see `adoptActiveDeviceId`), exactly as `BLEManager.bootstrapStore` re-points the WRITE side.
    /// #814: a remove+re-add gives the strap a fresh id ("whoop-<uuid>"), so the Collector writes today's
    /// raw under THAT id while the dashboard kept reading "my-whoop" and snapped to a stale day. Now the
    /// read side follows the same active id the write side does. NOT a `let` for that reason; `private(set)`
    /// so only `adoptActiveDeviceId` can move it.
    private(set) var deviceId: String
    /// Source id for on-device computed scores (recovery/strain/sleep derived from the raw strap
    /// streams by IntelligenceEngine). Merged UNDER the imported `deviceId` rows at read time, so a
    /// real WHOOP import always wins and the strap-only user still gets a populated dashboard.
    private var computedDeviceId: String { deviceId + "-noop" }

    /// The CANONICAL imported/computed id ("my-whoop" + its "-noop" sibling). The WHOOP-IMPORT and the
    /// engine's computed write target stay STABLE here forever (they never follow the active strap), so a
    /// remove+re-add never orphans the history a prior import/score banked. `deviceId` follows the active
    /// strap so today's LIVE raw under a re-added strap's "whoop-<uuid>" id still surfaces (#814); reads
    /// take the UNION of the two so BOTH the live strap AND the canonical history reach the dashboard.
    /// When the active strap IS the canonical id (single-device install) the union collapses to one id and
    /// is byte-identical to the pre-union behaviour.
    private var canonicalDeviceId: String { Self.whoopSource }
    private var canonicalComputedId: String { Self.whoopSource + "-noop" }

    /// The distinct IMPORTED/MEASURED source ids to union for a dashboard read: the active strap (live raw,
    /// #814) and the canonical imported id. Active strap FIRST so per-day dedup lets the measured/live row
    /// win over the imported one. Deduped, so a single-device install (active id == canonical) reads one id.
    private var importedReadIds: [String] {
        deviceId == canonicalDeviceId ? [deviceId] : [deviceId, canonicalDeviceId]
    }
    /// The distinct COMPUTED ("-noop") source ids to union: the active strap's computed sibling and the
    /// canonical computed sibling. Same dedup rule as `importedReadIds`.
    private var computedReadIds: [String] {
        computedDeviceId == canonicalComputedId ? [computedDeviceId] : [computedDeviceId, canonicalComputedId]
    }
    private var store: WhoopStore?

    /// Daily metrics (recovery/strain/sleep/HRV/RHR…) over the recent window, oldest→newest.
    @Published var days: [DailyMetric] = []
    /// Cached sleep sessions over the recent window, oldest→newest.
    @Published var sleeps: [CachedSleepSession] = []
    /// Imported (export-verbatim) sleep figures by day. Empty until a WHOOP import lands.
    @Published var importedSleep: [String: ImportedSleepFigures] = [:]
    @Published var loaded = false
    /// How much history each source currently holds, recomputed on every `refresh()`. Powers the
    /// Data Sources "Freshness Pipeline" card so the user can see imported vs computed vs Apple coverage.
    @Published private(set) var freshness: RepositoryFreshness = .empty
    /// Daily metric rows with source provenance, used by vital-sign surfaces that need honest
    /// "WHOOP import / NOOP computed / Apple Health" captions instead of a silent merged row.
    @Published private(set) var vitalRows: [SourcedDailyMetric] = []
    /// Monotonic counter bumped on every successful `refresh()`. Intraday-updating views key their
    /// data load on this so they reload when fresh strap data lands , `today?.day` alone is a stable
    /// date string within a day and would freeze e.g. the Today HR trend until the date rolls over.
    @Published private(set) var refreshSeq = 0

    /// Workouts & GPS test mode (Test Centre): the tagged sink for the `.workouts` diagnostic lines
    /// (auto-detect inputs/thresholds/why, cross-source dedup decisions). Default nil (inert) so tests +
    /// non-prod inits get the byte-identical untraced path; AppModel wires it to `live.append(log:domain:)`.
    /// We ALWAYS check `TestCentre.active(.workouts)` BEFORE building any line (the gate is one UserDefaults
    /// bool read), so the read facades pay nothing when the mode is off. Diagnostic only - it never changes
    /// the workout list the query returns.
    var workoutsLog: ((String) -> Void)?

    /// Emit one Workouts & GPS test-mode line iff the mode is on and a sink is wired. The cheap
    /// `TestCentre.active(.workouts)` gate is checked BEFORE `build()` runs, so the string is never
    /// constructed when the mode is off (the @autoclosure defers it).
    private func emitWorkouts(_ build: @autoclosure () -> String) {
        guard TestCentre.active(.workouts), let workoutsLog else { return }
        workoutsLog(build())
    }

    init(deviceId: String) { self.deviceId = deviceId }

    /// Re-point the read model's ACTIVE-strap id at the device registry's active device, so a re-added
    /// strap's LIVE raw (written under its fresh "whoop-<uuid>" id) surfaces on the dashboard (#814).
    /// Called by AppModel on every registry active-id change. Idempotent + best-effort: an empty/unchanged
    /// id is a no-op, so a single-device install (active id still "my-whoop") never moves and is byte-
    /// identical to the pre-#814 behaviour. This moves only the ACTIVE-strap read id; the dashboard reads
    /// the UNION of it and the canonical "my-whoop" (see `importedReadIds`), so the canonical imported/
    /// computed history a prior import banked still surfaces too (it is NOT orphaned by the move). The
    /// import + computed WRITE targets stay STABLE on the canonical id elsewhere, this is read-side only.
    /// Returns true when the id actually changed (so the caller can `refresh()` the now-restapped caches).
    @discardableResult
    func adoptActiveDeviceId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != deviceId else { return false }
        deviceId = trimmed
        return true
    }

    #if DEBUG
    /// Inject a pre-opened store so unit tests can exercise the read facades (e.g. `timelineSeries`)
    /// against an in-memory `WhoopStore` without touching the on-disk path. DEBUG-only test seam.
    func setStoreForTesting(_ s: WhoopStore) { self.store = s }
    #endif

    // MARK: - Union reads (active strap + canonical)
    //
    // Each helper reads the SAME store query across `importedReadIds` (active strap + canonical "my-whoop")
    // and concatenates the rows, ACTIVE STRAP FIRST. The callers feed the concatenated rows into the SAME
    // per-day dedup they already used (mergeDaily/mergeSleep key by day; the daily/series facades dedup
    // explicitly below), so per local-day the active-strap (live/measured) row wins over the canonical
    // (imported) one and nothing double-counts. A single-device install reads one id (the union collapses).

    /// Daily-metric rows across the imported union for a day range, DEDUPED per day with the ACTIVE STRAP
    /// winning over the canonical import (a live/measured row beats an imported one for the same day). The
    /// single returned row per day feeds the existing imported-vs-computed `mergeDaily` unchanged.
    private func unionDailyMetrics(store: WhoopStore, from: String, to: String) async -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for id in importedReadIds {   // active strap FIRST → it claims each day, canonical only fills gaps
            for m in (try? await store.dailyMetrics(deviceId: id, from: from, to: to)) ?? [] where byDay[m.day] == nil {
                byDay[m.day] = m
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// metricSeries points across the imported union for a key + day range, DEDUPED per day with the active
    /// strap winning (same precedence as `unionDailyMetrics`).
    private func unionMetricSeries(store: WhoopStore, key: String, from: String, to: String) async -> [MetricPoint] {
        var byDay: [String: MetricPoint] = [:]
        for id in importedReadIds {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] where byDay[p.day] == nil {
                byDay[p.day] = p
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Sleep sessions across the imported union for a ts range, keeping ALL sessions per day (a nap + a main
    /// night both survive) and dropping only EXACT-duplicate blocks (same start+end) recorded under both
    /// union ids. The downstream `mergeSleep`/`userEditedDays` do the per-day collapse, exactly as before.
    private func unionSleepSessions(store: WhoopStore, from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: importedReadIds, from: from, to: to, limit: limit))
    }

    /// Computed ("-noop") daily-metric rows across the computed union, DEDUPED per day (active strap's
    /// computed sibling wins over the canonical computed sibling).
    private func unionComputedDailyMetrics(store: WhoopStore, from: String, to: String) async -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for id in computedReadIds {
            for m in (try? await store.dailyMetrics(deviceId: id, from: from, to: to)) ?? [] where byDay[m.day] == nil {
                byDay[m.day] = m
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Computed ("-noop") sleep sessions across the computed union, keeping ALL sessions per day and dropping
    /// only EXACT-duplicate blocks recorded under both computed siblings.
    private func unionComputedSleepSessions(store: WhoopStore, from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: computedReadIds, from: from, to: to, limit: limit))
    }

    /// ALL sleep blocks across `ids` for a ts range, concatenated (NOT collapsed to one per day, used by
    /// `allSleepSessions`, which expands split sleeps). Active strap first.
    private func unionRawSleepBlocks(store: WhoopStore, ids: [String], from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        var blocks: [CachedSleepSession] = []
        for id in ids {
            blocks += (try? await store.sleepSessions(deviceId: id, from: from, to: to, limit: limit)) ?? []
        }
        return blocks
    }

    /// Drop blocks that share a (startTs, endTs) key, the same physical session recorded under both union
    /// ids, keeping the first (active strap). Preserves genuinely distinct blocks (naps + main night).
    nonisolated private static func dedupBlocks(_ blocks: [CachedSleepSession]) -> [CachedSleepSession] {
        var seen = Set<String>()
        var out: [CachedSleepSession] = []
        for b in blocks {
            let key = "\(b.startTs)-\(b.endTs)"
            if seen.insert(key).inserted { out.append(b) }
        }
        return out
    }

    /// Drop workout rows that share a (startTs, endTs, sport, source) key, the same session recorded under
    /// both union device ids, keeping the first (active strap). Distinct sessions are preserved; the
    /// downstream `dedupCrossSource` still collapses strap-vs-Apple twins by time.
    nonisolated private static func dedupWorkoutsByNaturalKey(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        var seen = Set<String>()
        var out: [WorkoutRow] = []
        for r in rows {
            let key = "\(r.startTs)-\(r.endTs)-\(r.sport)-\(r.source)"
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }

    /// Latest HR-sample ts across the imported union, or nil. The auto-land Today anchor (#597) uses this,
    /// so a re-added strap's live raw AND the canonical history both count toward "the most recent data day".
    private func unionLatestHRSampleTs(store: WhoopStore) async -> Int? {
        var latest: Int?
        for id in importedReadIds {
            if let ts = (try? await store.latestHRSampleTs(deviceId: id)) ?? nil {
                latest = max(latest ?? ts, ts)
            }
        }
        return latest
    }

    /// Today's row, by the device's LOGICAL local day , NOT just the newest stored row, which after a
    /// historical import was months-old data shown as today's hero (issue #23). The logical day rolls at
    /// 04:00 local (see `logicalDayKey`), so between midnight and 4am we keep resolving the prior logical
    /// day's row instead of an empty new-calendar-day row that blanks the dashboard (#144). nil if no row
    /// for that day yet (the dashboard then shows its empty/pending state). Presentation-only , stored
    /// row keys are untouched.
    ///
    /// Non-UTC pre-04:00 carve-out (#304): a user who falls asleep before midnight and wakes before the
    /// 04:00 rollover has the just-finished night banked under the NEW local calendar day (sleep is keyed
    /// by the local wake-day , `mergeSleep` / IntelligenceEngine), while `logicalDayKey` still points at
    /// yesterday. Resolving strictly by logical day would then surface the PREVIOUS night. So: if the
    /// local calendar day differs from the logical day AND a row for the local day has a banked night
    /// (`totalSleepMin != nil`), prefer that row. Otherwise fall back to the logical-day row , which keeps
    /// the #144 anti-blank guard (no night banked yet ⇒ keep yesterday's logical row, never blank).
    var today: DailyMetric? {
        let now = Date()
        return Repository.resolveToday(days: days,
                                       logicalKey: Repository.logicalDayKey(now),
                                       localKey: Repository.localDayKey(now))
    }

    /// Pure resolver behind `today` (extracted so the #304 boundary is testable without a live clock):
    /// prefer the LOCAL-calendar-day row when it differs from the logical day AND has a banked night
    /// (`totalSleepMin != nil`); otherwise the logical-day row (preserving the #144 anti-blank guard).
    /// `localKey == logicalKey` (the common daytime case) collapses to the plain logical-day lookup.
    nonisolated static func resolveToday(days: [DailyMetric], logicalKey: String, localKey: String) -> DailyMetric? {
        if localKey != logicalKey,
           let localRow = days.last(where: { $0.day == localKey && $0.totalSleepMin != nil }) {
            return localRow
        }
        return days.last(where: { $0.day == logicalKey })
    }
    /// The trailing 7 CALENDAR days ending today (for the week strip), oldest→newest , not the last 7
    /// stored rows, which on a stale import were old data. ISO yyyy-MM-dd compares chronologically.
    var week: [DailyMetric] {
        let cutoff = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        return days.filter { $0.day >= cutoff }
    }

    /// Source-aware rows for vital-sign cards. During previews/tests that set `days` directly,
    /// fall back to the merged local cache so the component still renders.
    var vitalMetricRows: [SourcedDailyMetric] {
        vitalRows.isEmpty ? days.map { SourcedDailyMetric(metric: $0, source: .localCache) } : vitalRows
    }

    /// Canonical source ids the resolver knows how to cross-reference. The strap's actual id is
    /// `deviceId` (and its computed sibling `deviceId + "-noop"`); these are the FIXED ids.
    static let whoopSource = "my-whoop"
    static let appleHealthSource = "apple-health"
    static let healthConnectSource = "health-connect"

    /// Imported wearable-export sources whose DAILY aggregates (HRV / resting HR / sleep) can be scored
    /// for a NOOP Charge/Rest on an import-only day, exactly like a live day (#823). These carry no raw HR
    /// stream, so the source-only fold in IntelligenceEngine scores them from the daily aggregate vs the
    /// person's own baseline. Matches `WearableBrand.sourceId` plus Health Connect (Android imports HC's
    /// daily metrics under the strap source, but a sideloaded/standalone HC source id is covered too).
    static let wearableImportSources = ["oura-import", "fitbit-import", "garmin-import", healthConnectSource]

    /// `yyyy-MM-dd` in the device's local zone, matching how `DailyMetric.day` is stored.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func localDayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    /// The hour the LOGICAL day rolls (04:00 local). Between midnight and this hour, "Today" stays put.
    nonisolated static let logicalDayRolloverHour = 4

    /// The LOGICAL local day for `now` , the calendar date of `now - rolloverHour hours`. Rolls at
    /// 04:00 local rather than midnight, so the small hours after midnight still resolve to the prior
    /// calendar date's row instead of an empty new-calendar-day row (#144). Pure + injectable so the
    /// boundary is testable (23:59 → same day, 01:00 → previous day, 04:01 → new day). Presentation-only:
    /// used solely to pick which stored row is Today and to anchor the Today HR-trend window start; stored
    /// row keys are never rewritten.
    static func logicalDay(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> Date {
        now.addingTimeInterval(-Double(rolloverHour) * 3_600)
    }

    /// `yyyy-MM-dd` key for the logical day of `now` (see `logicalDay`).
    static func logicalDayKey(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> String {
        localDayKey(logicalDay(now, rolloverHour: rolloverHour))
    }

    /// Start of the logical day (its real calendar midnight) for `now`, in `calendar`'s zone , the anchor
    /// for the Today HR-trend window so it spans from the logical day's 00:00 rather than restarting at the
    /// new calendar midnight while we're still showing yesterday's logical day in the small hours (#144).
    static func logicalDayStart(_ now: Date, calendar: Calendar = .current,
                                rolloverHour: Int = logicalDayRolloverHour) -> Date {
        calendar.startOfDay(for: logicalDay(now, rolloverHour: rolloverHour))
    }

    private func ensureStore() async -> WhoopStore? {
        if let store { return store }
        // Don't swallow the open failure with `try?` (#222): an import-time open failure (e.g. the iOS
        // data-protected store while the device is locked) was previously invisible, surfacing only as a
        // generic "Couldn't open the local store." Log the real error so the cause is diagnosable.
        let path: String
        do {
            path = try StorePaths.defaultDatabasePath()
        } catch {
            NSLog("WhoopStore: ensureStore FAILED resolving DB path , \(error)")
            return nil
        }
        let s: WhoopStore
        do {
            s = try await WhoopStore(path: path)
        } catch {
            let ns = error as NSError
            NSLog("WhoopStore: ensureStore FAILED opening store , \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
            return nil
        }
        try? await s.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
        store = s
        return s
    }

    /// Expose the shared store handle (used by the importer to persist mapped rows).
    func storeHandle() async -> WhoopStore? { await ensureStore() }

    /// CAPTURE-D (#797): the on-device DATA VOLUME read FRESH from the STORE (never the `@Published`
    /// dashboard caches), for the Display & Performance test mode's `dataVolume` line. dbRows is the raw
    /// decoded-stream footprint; importedDays is the count of imported daily-metric rows under the active
    /// strap id (the #799 import surface, the SAME `deviceId` rows `importedDays` is derived from);
    /// workouts is the recorded/detected workout-row count. Resolves the active strap id from `deviceId`
    /// (already re-pointed to the registry's activeDeviceId, #814) so it reads the right source, not the
    /// hardcoded legacy id. Returns nil when the store can't be opened. Pure store reads; no merge, no
    /// scoring, no @Published mutation, so calling it never perturbs the screens it is measuring.
    func dataVolumeSnapshot() async -> DataVolume? {
        guard let store = await ensureStore() else { return nil }
        let dbRows = (try? await store.storageStats().decodedRows) ?? 0
        // Imported daily-metric rows live under the UNION of the active strap + the canonical "my-whoop"
        // (computed scores are merged UNDER them from the computed siblings). A wide day range covers the
        // full local-history span an import can carry. Union-deduped per day so a re-add's history still counts.
        let imported = await unionDailyMetrics(store: store, from: "0000-01-01", to: "9999-12-31")
        // Whole recordable epoch in unix seconds [0, ~2^31) so every recorded workout row is counted.
        var workouts: [WorkoutRow] = []
        for id in importedReadIds { workouts += (try? await store.workouts(deviceId: id, from: 0, to: 4_102_444_800, limit: 1_000_000)) ?? [] }
        workouts = Self.dedupWorkoutsByNaturalKey(workouts)
        // lastRenderRows = the size of the merged DAILY set the dashboard list/charts actually render: the
        // union of distinct days across the three daily sources (imported strap + on-device computed + Apple)
        // over the full local-history window. This is the read-set whose size drives the post-import list/
        // chart lag (#797) - so the trace pairs frame stats with "how many rows it was rendering over".
        let computed = await unionComputedDailyMetrics(store: store, from: "0000-01-01", to: "9999-12-31")
        let apple = (try? await store.dailyMetrics(deviceId: Self.appleHealthSource, from: "0000-01-01", to: "9999-12-31")) ?? []
        var renderDays = Set<String>()
        for m in imported { renderDays.insert(m.day) }
        for m in computed { renderDays.insert(m.day) }
        for m in apple { renderDays.insert(m.day) }
        return DataVolume(dbRows: dbRows, importedDays: imported.count,
                          workouts: workouts.count, lastRenderRows: renderDays.count)
    }

    /// Checkpoint the WAL into the main DB file if the store is already open, so a file-level
    /// backup captures everything. No-op (returns false) if no handle exists yet , the caller
    /// then copies the on-disk files as-is, which still includes the -wal sidecar.
    func checkpointForBackup() async -> Bool {
        guard let store else { return false }
        do { try await store.checkpointWAL(); return true } catch { return false }
    }

    /// One refresh's fully-merged dashboard caches, computed OFF the main actor (FIX 3) and applied to the
    /// `@Published` props in a single main-actor batch. Every member is an `Equatable` value type. NOT
    /// marked `Sendable` (its `DailyMetric`/`CachedSleepSession` members aren't formally `Sendable`); it
    /// crosses the `Task.detached` boundary the same way the engine's `DayResult` already does under this
    /// project's `minimal` strict-concurrency setting (SWIFT_STRICT_CONCURRENCY: minimal, Swift 5 mode).
    private struct MergedCaches {
        let importedSleep: [String: ImportedSleepFigures]
        let days: [DailyMetric]
        let sleeps: [CachedSleepSession]
        let vitalRows: [SourcedDailyMetric]
        let freshness: RepositoryFreshness
    }

    /// Reload the dashboard caches over the last `nDays`, merging imported history with the
    /// on-device computed scores so a strap-only user still gets a populated dashboard.
    ///
    /// FIX 3: a fresh-import / first-launch analyze tail fires `refresh()` many times in quick succession.
    /// Two costs made each one expensive: (1) the `mergeDaily`/`mergeSleep`/`sourceRows` O(n log n) sorts
    /// ran on the MAIN actor over thousands of rows, and (2) `refreshSeq` bumped UNCONDITIONALLY, so every
    /// bump re-fired `TodayView.loadAll()` (~28 sequential reads + 28 @State writes) even when nothing
    /// changed. Now the sorts run in a detached task and the merged result is DIFFED against the current
    /// caches , when nothing changed we skip BOTH the re-publish and the `refreshSeq` bump, so the redundant
    /// tail refreshes don't each detonate a full Today reload. The "one consistent publish per refresh"
    /// guarantee is kept: on a real change every prop + the seq are assigned in ONE main-actor batch.
    /// Monotonic ordering token (#review): refresh() now suspends on an off-actor merge between the store
    /// reads and the publish, so two overlapping refresh() calls (e.g. a 120-day backfill refresh and the
    /// 4000-day analyze-tail refresh) could resume + publish OUT OF ORDER, an older stale merge clobbering a
    /// newer one. Each call captures the token at entry and only publishes if it is still the latest. Not
    /// @Published (pure ordering, never drives the UI); race-free since Repository is @MainActor.
    private var refreshGen = 0

    /// #849: the `refreshSeq` value at which Today last ran its heavy history-wide reload (the ~40 reads +
    /// per-day raw-HR pass). Lives HERE, on the long-lived Repository, not in TodayView's `@State`, so it
    /// SURVIVES a Today re-mount (tab-away + return / an Apple-Health import that recreates the view). A bare
    /// re-mount resets TodayView's `@State` but `refreshSeq` is unchanged, so the screen re-ran the full
    /// reload for byte-identical data every time. Today now compares this against the live `refreshSeq` and
    /// skips the reload when nothing has changed since it last loaded. `-1` = never loaded this launch, so the
    /// first load (seq 0) always runs. Not @Published (pure load-bookkeeping, never drives the UI).
    var todayHistoryWideLoadedSeq = -1
    /// #849: the last history-wide snapshot Today built, so a re-mount can RESTORE it (in-memory, no queries)
    /// instead of re-running the heavy reload. Paired with `todayHistoryWideLoadedSeq`. Not @Published.
    var todayHistoryWideCache: TodayHistoryWideCache?

    /// #833 (Insights freeze): macOS destroys + cold-mounts the NavigationSplitView detail on every sidebar
    /// switch (RootView keys it with `.id`), so InsightsView's `@State` is torn down each time and its
    /// `load()` re-read full history off the @MainActor on every visit. Mirroring Today's #849 marker, this
    /// is the `refreshSeq` value at which Insights last ran its heavy load. Lives HERE on the long-lived
    /// Repository so it SURVIVES the re-mount; `-1` = never loaded this launch, so the first load always runs.
    /// Not @Published (pure load-bookkeeping, never drives the UI).
    var insightsLoadedSeq = -1
    /// #833: the dayKey Insights last loaded for, paired with `insightsLoadedSeq`. A day rollover (the journal
    /// chips re-key on it) must still re-load even at an unchanged `refreshSeq`, so the cache only short-
    /// circuits when BOTH the seq AND this dayKey match the current load. Not @Published.
    var insightsLoadedDayKey = ""
    /// #833: the computed dictionaries + activity costs InsightsView.load() last built, so a same-seq re-mount
    /// RESTORES them in-memory (no store queries) instead of re-running the heavy load. Not @Published.
    var insightsCache: InsightsLoadCache?

    func refresh(days nDays: Int = 4000) async {
        guard let store = await ensureStore() else { return }
        refreshGen &+= 1
        let myGen = refreshGen
        let now = Date()
        let fromDay = Self.dayString(now.addingTimeInterval(-Double(nDays) * 86_400))
        let toDay = Self.dayString(now.addingTimeInterval(86_400))
        let nowTs = Int(now.timeIntervalSince1970)
        let lo = nowTs - nDays * 86_400, hi = nowTs + 86_400

        // UNION the active strap (live raw, #814) with the canonical "my-whoop" import so a re-added strap's
        // live data AND the canonical history both surface, deduped per day (active strap wins). Collapses to
        // a single id on a single-device install (byte-identical to before).
        let imported = await unionDailyMetrics(store: store, from: fromDay, to: toDay)
        let computed = await unionComputedDailyMetrics(store: store, from: fromDay, to: toDay)
        let apple = (try? await store.dailyMetrics(deviceId: Self.appleHealthSource, from: fromDay, to: toDay)) ?? []
        let impSleep = await unionSleepSessions(store: store, from: lo, to: hi)
        let compSleep = await unionComputedSleepSessions(store: store, from: lo, to: hi)

        // Export-verbatim sleep figures (long-format metricSeries rows from WhoopImporter).
        // SleepView prefers these per day over its APPROXIMATE recomputations.
        let perf = await unionMetricSeries(store: store, key: "sleep_performance", from: fromDay, to: toDay)
        let cons = await unionMetricSeries(store: store, key: "sleep_consistency", from: fromDay, to: toDay)
        let need = await unionMetricSeries(store: store, key: "sleep_need_min", from: fromDay, to: toDay)
        let debt = await unionMetricSeries(store: store, key: "sleep_debt_min", from: fromDay, to: toDay)

        // Merge + sort OFF the main actor (FIX 3): the figures build, the two O(n log n) daily/sleep merges,
        // the source-row sort, and the freshness counts are all pure over the rows just read, so they run in
        // a detached task and the main actor stays free for SwiftUI during a deep-history refresh.
        let merged: MergedCaches = await Task.detached(priority: .utility) {
            var fig: [String: ImportedSleepFigures] = [:]
            for p in perf { fig[p.day, default: ImportedSleepFigures()].performancePct = p.value }
            for p in cons { fig[p.day, default: ImportedSleepFigures()].consistencyPct = p.value }
            for p in need { fig[p.day, default: ImportedSleepFigures()].needMin = p.value }
            for p in debt { fig[p.day, default: ImportedSleepFigures()].debtMin = p.value }
            // H5 (#509): a night the user hand-edited (userEdited) must keep its corrected sleep figures even
            // when a WHOOP/Apple import also covers that day. The computed ("-noop") session carries the edit,
            // and IntelligenceEngine re-keys the computed DAILY row from it; collect those edited days so the
            // merge lets the computed row's SLEEP fields win there (imports still win on every un-edited day).
            let editedDays = Self.userEditedDays(compSleep)
            return MergedCaches(
                importedSleep: fig,
                days: Self.mergeDaily(imported: imported, computed: computed, userEditedDays: editedDays),
                sleeps: Self.mergeSleep(imported: impSleep, computed: compSleep),
                vitalRows: Self.sourceRows(imported: imported, computed: computed, apple: apple),
                freshness: Self.computeFreshness(imported: imported, computed: computed, apple: apple,
                                                 importedSleeps: impSleep, computedSleeps: compSleep))
        }.value

        // Generation guard (#review): if a newer refresh() started while this one merged off-actor, drop
        // this now-stale result so it can't clobber the newer caches or re-fire loadAll out of order.
        guard myGen == refreshGen else { return }

        // DIFF before publishing (FIX 3): if this refresh produced byte-identical caches AND we've already
        // loaded once, skip the re-publish and the `refreshSeq` bump entirely , assigning an equal value to
        // an @Published prop still fires objectWillChange, so the skip must cover the assignments too. This
        // is what stops the analyze-tail's burst of refresh() calls each re-firing TodayView.loadAll().
        let unchanged = loaded
            && merged.days == days
            && merged.sleeps == sleeps
            && merged.importedSleep == importedSleep
            && merged.vitalRows == vitalRows
            && merged.freshness == freshness
        guard !unchanged else { return }

        // One consistent publish per refresh: assign every cache, flip `loaded`, then bump `refreshSeq` so
        // the intraday-updating views reload exactly once for this real change.
        self.importedSleep = merged.importedSleep
        self.days = merged.days
        self.sleeps = merged.sleeps
        self.vitalRows = merged.vitalRows
        self.freshness = merged.freshness
        self.loaded = true
        self.refreshSeq += 1
    }

    /// Per-source coverage counts for the Freshness Pipeline card. Pure over the rows already read.
    /// `nonisolated` (FIX 3) so `refresh()`'s detached merge task can call it off the main actor.
    nonisolated private static func computeFreshness(imported: [DailyMetric], computed: [DailyMetric],
                                         apple: [DailyMetric], importedSleeps: [CachedSleepSession],
                                         computedSleeps: [CachedSleepSession]) -> RepositoryFreshness {
        let days = (imported + computed + apple).map(\.day)
        return RepositoryFreshness(
            importedDays: imported.count,
            computedDays: computed.count,
            appleDays: apple.count,
            importedSleeps: importedSleeps.count,
            computedSleeps: computedSleeps.count,
            earliestDay: days.min(),
            latestDay: days.max()
        )
    }

    /// Imported daily values win field-by-field; computed rows fill only nil imported fields.
    /// This preserves official export/import values while allowing fresh local analysis to populate
    /// Charge, skin temperature deviation, activity totals, or other fields missing from that row.
    ///
    /// H5 (#509): a day in `userEditedDays` is one the user hand-edited the sleep of (a corrected
    /// bed/wake time, an added nap, a deleted night). For those days the COMPUTED row's SLEEP fields
    /// take precedence over the import , otherwise a re-imported WHOOP/Apple night would silently mask
    /// the user's correction. Non-sleep fields (recovery/strain/HRV/RHR/activity…) still follow the
    /// normal imports-win merge, and every NON-edited day is unchanged.
    nonisolated static func mergeDaily(imported: [DailyMetric], computed: [DailyMetric],
                                       userEditedDays: Set<String> = []) -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for d in computed { byDay[d.day] = d }
        for d in imported {
            if let existing = byDay[d.day] {
                let merged = d.fillingNilFields(from: existing)
                byDay[d.day] = userEditedDays.contains(d.day)
                    ? merged.takingSleepFields(from: existing)   // edited night: computed sleep wins
                    : merged
            } else {
                byDay[d.day] = d
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// The set of LOCAL wake-days that carry a user-edited sleep session , keyed exactly as
    /// `DailyMetric.day` is (the engine's cached-offset local-day keyer, matching `mergeSleep.endDay`).
    /// Drives the H5 edit-merge precedence in `mergeDaily`.
    nonisolated static func userEditedDays(_ sessions: [CachedSleepSession]) -> Set<String> {
        var days = Set<String>()
        for s in sessions where s.userEdited {
            let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            days.insert(AnalyticsEngine.dayString(s.endTs, offsetSec: offsetSec))
        }
        return days
    }

    /// Daily rows tagged with the source that supplied them, for the source-aware vital-sign cards.
    /// One entry per (source, day) , the consumer resolves precedence per metric (imported > computed
    /// > Apple); ordered by day, then source priority, so a stable list reaches the UI.
    /// `nonisolated` (FIX 3) so `refresh()`'s detached merge task can call it off the main actor.
    nonisolated private static func sourceRows(imported: [DailyMetric], computed: [DailyMetric],
                                   apple: [DailyMetric]) -> [SourcedDailyMetric] {
        (imported.map { SourcedDailyMetric(metric: $0, source: .whoopImport) }
            + computed.map { SourcedDailyMetric(metric: $0, source: .noopComputed) }
            + apple.map { SourcedDailyMetric(metric: $0, source: .appleHealth) })
            .sorted { lhs, rhs in
                if lhs.metric.day == rhs.metric.day {
                    return lhs.source.vitalPriority < rhs.source.vitalPriority
                }
                return lhs.metric.day < rhs.metric.day
            }
    }

    /// Same precedence for sleep sessions, keyed by the day the night ends on.
    /// Keys through `AnalyticsEngine.dayString(_:offsetSec:)` , the canonical LOCAL-day keyer
    /// `analyzeDay` attributes sessions with , NOT the unzoned `Repository.dayFormatter`, which formats
    /// in whatever the live device zone is and so disagreed with the engine's cached-offset attribution
    /// across a midnight boundary for non-UTC users (the Swift half of #406; mirrors the Android #304 fix
    /// pinned by MergeSleepLocalDayTest).
    nonisolated private static func mergeSleep(imported: [CachedSleepSession], computed: [CachedSleepSession]) -> [CachedSleepSession] {
        func endDay(_ s: CachedSleepSession) -> String {
            let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            return AnalyticsEngine.dayString(s.endTs, offsetSec: offsetSec)
        }
        // #715 — preserve EVERY session (a day with a main night + a nap must keep both); imported still
        // wins per end-day. Shared, unit-tested grouping (WhoopStore.SleepMerge / SleepMergeTests) replaces
        // the old per-day dictionary that silently dropped a second same-day session.
        return SleepMerge.merge(imported: imported, computed: computed, endDay: endDay)
    }

    // MARK: - Detail passthroughs

    func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric] {
        guard let store = await ensureStore() else { return [] }
        return await unionDailyMetrics(store: store, from: fromDay, to: toDay)
    }

    func hrSamples(from: Int, to: Int, limit: Int = 8000) async -> [HRSample] {
        guard let store = await ensureStore() else { return [] }
        // UNION the active strap + canonical so the HR trend renders whether the landed day's raw sits under
        // the re-added strap (live) or the canonical history. Deduped by ts (active strap wins) so an overlap
        // never double-counts; sorted ascending. Single-device install reads one id (byte-identical).
        guard deviceId != canonicalDeviceId else {
            return (try? await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        }
        var byTs: [Int: HRSample] = [:]
        for id in importedReadIds {
            for s in (try? await store.hrSamples(deviceId: id, from: from, to: to, limit: limit)) ?? [] where byTs[s.ts] == nil {
                byTs[s.ts] = s
            }
        }
        return byTs.values.sorted { $0.ts < $1.ts }
    }

    /// Logical day-start of the most recent day the active device has HR data for, or nil when the store is
    /// empty. Lets the Deep Timeline open on a day that actually has data instead of a possibly-empty today
    /// right after a history sync , the #597 root cause (the timeline was today-only with no way back).
    func latestDataDayStart() async -> Date? {
        guard let store = await ensureStore() else { return nil }
        guard let ts = await unionLatestHRSampleTs(store: store) else { return nil }
        return Self.logicalDayStart(Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Downsampled HR (mean bpm per `bucketSeconds`) for the strap, for a Today/24h trend chart.
    /// Aggregated in SQL so a full day never loads the raw ~1 Hz rows.
    func hrBuckets(from: Int, to: Int, bucketSeconds: Int = 300) async -> [HRBucket] {
        guard let store = await ensureStore() else { return [] }
        // UNION the active strap + canonical for the trend chart. Per bucket-start the active strap wins; a
        // raw HR window almost never overlaps between the two namespaces (different time periods), so the
        // per-bucket mean stays faithful. Single-device install reads one id (byte-identical).
        guard deviceId != canonicalDeviceId else {
            return (try? await store.hrBuckets(deviceId: deviceId, from: from, to: to, bucketSeconds: bucketSeconds)) ?? []
        }
        var byStart: [Int: HRBucket] = [:]
        for id in importedReadIds {
            for b in (try? await store.hrBuckets(deviceId: id, from: from, to: to, bucketSeconds: bucketSeconds)) ?? [] where byStart[b.ts] == nil {
                byStart[b.ts] = b
            }
        }
        return byStart.values.sorted { $0.ts < $1.ts }
    }

    func sleepSessions(from: Int, to: Int, limit: Int = 100) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        return await unionSleepSessions(store: store, from: from, to: to, limit: limit)
    }

    /// Every sleep BLOCK across BOTH sources, UN-deduplicated , so a split-sleep day (a nap
    /// + a main sleep, or any night recorded as multiple blocks) keeps ALL of its blocks.
    /// `sleeps` collapses each day to a single winner for the dashboard; this does not.
    ///
    /// Crucially this reads the on-device COMPUTED source (`computedDeviceId`) directly, not
    /// just the imported `deviceId`. A Bluetooth-only user (no WHOOP/Apple-Health import) has
    /// every block under the computed source, so a loader that only un-dedupes the imported
    /// device sees nothing to expand and silently falls back to the deduped one-per-day list ,
    /// hiding the day's extra blocks. Imported blocks still win on any day they cover (matching
    /// the dashboard's imported-wins merge); computed blocks fill days with no import.
    /// Oldest→newest by onset.
    func allSleepSessions(days: Int = 4000) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        // UNION the active strap + canonical (imported) and their computed siblings, keeping ALL blocks (not
        // one per day, this view expands split sleeps), but dropping any block that appears under BOTH union
        // ids (same start+end key) so a day present in both namespaces isn't double-listed.
        let imported = Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: importedReadIds, from: lo, to: hi))
        let computed = Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: computedReadIds, from: lo, to: hi))
        let cal = Calendar.current
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        var importedDays = Set<Date>()
        for s in imported { importedDays.insert(endDay(s)) }
        let computedKept = computed.filter { !importedDays.contains(endDay($0)) }
        return (imported + computedKept).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// The persisted per-epoch MOTION series for each of `starts` (detected session start keys), keyed by
    /// start (#407). Motion is written ONLY under the computed ("-noop") source by the engine, so we read
    /// there , and an imported-only night (no computed twin) simply has no motion (absent stays absent, an
    /// honest empty state, never a fabricated zero array). This does NOT resolve the night: the caller has
    /// already chosen the main-night GROUP (the 6.1.1 bridged group) and passes those blocks' starts; we
    /// only fetch each one's stored series so the Sleep tab can lay them along the hypnogram's timeline.
    /// A start with no stored series is omitted from the result (its key is absent).
    func sessionMotions(starts: [Int]) async -> [Int: [Double]] {
        guard !starts.isEmpty, let store = await ensureStore() else { return [:] }
        var out: [Int: [Double]] = [:]
        for start in starts {
            if let m = try? await store.sessionMotion(deviceId: computedDeviceId, sessionStart: start), !m.isEmpty {
                out[start] = m
            }
        }
        return out
    }

    /// The user's learned habitual midsleep (local time-of-day seconds), or nil under
    /// `SleepStageTotals.habitualMinDays` of history (cold-start). Computed EXACTLY as
    /// `IntelligenceEngine.computeHabitualMidsleep` does , the SAME raw imported + computed ("-noop")
    /// sleep-session union, one `HistoryBlock` per session (effective bounds, dayKey = the LOCAL calendar
    /// day of the midpoint), deferring to the SAME shared `SleepStageTotals.habitualMidsleepSec` pure
    /// function , so the Sleep tab's main-night pick aligns to the same value the analytics rollup used.
    /// The whole point of #547: the UI hero and the analytics daily total resolve to the SAME block for a
    /// shift/late sleeper, not just at cold-start. Reads a wide window so the distinct-day count comfortably
    /// clears the threshold; `habitualMidsleepSec` keeps the longest block per day, so window/order/source
    /// merge differences wash out. (#547)
    func habitualMidsleepSec(days: Int = 4000) async -> Int? {
        guard let store = await ensureStore() else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        // UNION active strap + canonical (imported) and their computed siblings, de-duplicating identical
        // blocks recorded under both ids so a day present in both namespaces doesn't double-weight the learner.
        let imported = Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: importedReadIds, from: lo, to: hi))
        let computed = Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: computedReadIds, from: lo, to: hi))
        let offsetSec = TimeZone.current.secondsFromGMT()
        let blocks = (imported + computed).compactMap { s -> SleepStageTotals.HistoryBlock? in
            let start = s.effectiveStartTs, end = s.endTs
            guard end > start else { return nil }
            let mid = start + (end - start) / 2
            let dayKey = AnalyticsEngine.dayString(mid, offsetSec: offsetSec)
            return SleepStageTotals.HistoryBlock(start: start, end: end, dayKey: dayKey)
        }
        return SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: offsetSec)
    }

    /// Hand-correct a night's bed (onset) and/or wake (end) time. `detectedStartTs` is the immutable
    /// detected key; the corrected onset is stored in `startTsAdjusted` so the key never moves (the
    /// recompute guard + daily override keep matching on it). The merged session list carries no source
    /// deviceId (same reason as the journal reads below), so this applies under BOTH the imported and
    /// computed sources , only the namespace that holds the night updates; the other is a no-op.
    ///
    /// Stages are **re-derived from the raw streams** for the corrected `[newStartTs, newEndTs]` window
    /// via `SleepStager.stageSession` , exactly what WHOOP does, so extending a boundary recovers real
    /// stages instead of a fabricated "awake" block. Only when the night has no raw data (an imported
    /// night) does it fall back to reshaping the stored summary (`SleepWindowReclip`). Refreshes so the
    /// hero re-reads the corrected night immediately.
    func editSleepTimes(detectedStartTs: Int, oldEndTs: Int, storedStagesJSON: String?,
                        newStartTs: Int, newEndTs: Int) async {
        guard let store = await ensureStore() else { return }
        // Re-derive stages from the raw streams for the corrected window; fall back to reshaping the
        // stored summary when the strap has no dense data there yet. The fallback fires for a genuine
        // imported night (no strap data at all) AND for the transient case where the user edits BEFORE
        // a sync has imported this window , the latter then self-heals on the next post-sync
        // `analyzeRecent` (see `selfHealEditedStages`), which re-derives the real stages once raw lands.
        let stagesJSON = await restageFromRaw(start: newStartTs, end: newEndTs)
            ?? SleepWindowReclip.reclip(stagesJSON: storedStagesJSON, sessionStart: detectedStartTs,
                                        oldEnd: oldEndTs, newStart: newStartTs, newEnd: newEndTs)
        // Apply to the source that actually OWNS this block. Try the computed source first; only fall
        // back to the imported source when no computed row matched , so we never edit a coincidental
        // same-startTs row in the other namespace (which the old unconditional double-write could do).
        let computedChanged = (try? await store.applySleepEdit(
            deviceId: computedDeviceId, detectedStartTs: detectedStartTs,
            newStartTs: newStartTs, newEndTs: newEndTs, stagesJSON: stagesJSON)) ?? 0
        if computedChanged == 0 {
            _ = try? await store.applySleepEdit(
                deviceId: deviceId, detectedStartTs: detectedStartTs,
                newStartTs: newStartTs, newEndTs: newEndTs, stagesJSON: stagesJSON)
        }
        await refresh()
    }

    /// Delete ONE sleep session , the `editSleepTimes` path minus the re-stage/re-insert, so the user can
    /// clear a misread or spurious night and the day recomputes as if it were never recorded (#68; Android
    /// parity , `WhoopRepository.deleteSleepSession`). `detectedStartTs` is the immutable detected key
    /// (`startTs`); `endTs` is the night's span, recorded in the tombstone so the engine's overlap test
    /// suppresses a re-detected onset that drifts second-to-second.
    ///
    /// Two durable effects, mirroring the workout-dismiss path:
    ///  1. delete the row from whichever namespace OWNS it , try the computed source first, fall back to
    ///     the imported `deviceId` only when no computed row matched, exactly as `editSleepTimes` applies
    ///     its edit (the merged session list carries no source deviceId, so we resolve the owner here and
    ///     never delete a coincidental same-startTs row in the other namespace);
    ///  2. persist a `dismissedSleep` span in UserDefaults so the next `analyzeRecent` re-detection doesn't
    ///     simply regenerate the night , the engine's sleep guard now skips any re-detected session
    ///     overlapping a dismissed span (just as the dismissed-WORKOUT spans hide a re-derived bout).
    /// Refreshes so the hero re-reads without the deleted night immediately.
    func deleteSleepSession(detectedStartTs: Int, endTs: Int) async {
        guard let store = await ensureStore() else { return }
        // Record the durable tombstone first (idempotent) so a delete that races a recompute still wins.
        var spans = dismissedSleepSpans
        let token = "\(detectedStartTs):\(endTs)"
        if !spans.contains(token) { spans.append(token); dismissedSleepSpans = spans }
        // Delete from the namespace that actually owns the row , computed first, imported as a fallback.
        let computedDeleted = (try? await store.deleteSleepSession(
            deviceId: computedDeviceId, startTs: detectedStartTs)) ?? 0
        if computedDeleted == 0 {
            _ = try? await store.deleteSleepSession(deviceId: deviceId, startTs: detectedStartTs)
        }
        await refresh()
    }

    /// Durable "user deleted this night" tombstones as "startTs:endTs" strings, persisted in UserDefaults
    /// (the macOS `CachedSleepSession` lives in the WhoopStore Journal file, which this layer must not
    /// extend with a new table , the same reason dismissed WORKOUT spans live here, not in the DB). The
    /// re-detector in `IntelligenceEngine.analyzeRecent` consults `dismissedSleepWindows` so a deleted
    /// night that re-detects stays gone. (#68; Android twin: the `dismissedSleep` Room table.)
    private var dismissedSleepSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: Repository.dismissedSleepDefaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Repository.dismissedSleepDefaultsKey) }
    }

    /// UserDefaults key holding the dismissed-sleep spans (see `dismissedSleepSpans`).
    static let dismissedSleepDefaultsKey = "sleep.dismissedSessions"

    /// Parsed dismissed-sleep windows for the engine's re-detection guard. Malformed / non-positive-width
    /// entries are dropped so a corrupt value can never hide everything (mirrors `WorkoutSource`'s parser).
    func dismissedSleepWindows() -> [(start: Int, end: Int)] {
        dismissedSleepSpans.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (a, b)
        }
    }

    /// Manually ADD a missed sleep session , typically a daytime NAP the detector didn't pick up (#508).
    /// Stages it from the raw streams over `[startTs, endTs]` (exactly the editing path's `restageFromRaw`),
    /// falling back to a single "awake" block when the strap has no dense data there yet , the post-sync
    /// self-heal then swaps in real stages once the raw lands. Written under the COMPUTED source as its OWN
    /// separate session row with `userEdited = 1`, so the recompute overlap guard preserves it and it is
    /// NEVER folded into the night's main sleep (which would mislabel awake daytime as light sleep). Purely
    /// additive , `insertManualSleepSession` no-ops if a session already exists at that exact onset.
    func addManualNap(startTs: Int, endTs: Int) async {
        guard let store = await ensureStore(), endTs > startTs else { return }
        // Stage from raw over the chosen window; fall back to a single awake block when the strap has no
        // dense data there yet (the self-heal re-stages once raw arrives). A nap's efficiency is the asleep
        // fraction of the staged window; nil for the fallback (no real stages yet).
        let stagesJSON = await restageFromRaw(start: startTs, end: endTs)
            ?? AnalyticsEngine.encodeStages([StageSegment(start: startTs, end: endTs, stage: "wake")])
        let efficiency = sleepEfficiency(fromStagesJSON: stagesJSON)
        _ = try? await store.insertManualSleepSession(
            deviceId: computedDeviceId, startTs: startTs, endTs: endTs,
            efficiency: efficiency, stagesJSON: stagesJSON)
        await refresh()
    }

    /// Asleep fraction (light+deep+rem ÷ total in-bed) of a segment-array `stagesJSON`, or nil when the
    /// JSON is the fallback awake-only block / unparseable. Used to seed a manually-added nap's efficiency
    /// so its hypnogram footer reads sensibly before the next recompute re-derives it. (#508)
    private func sleepEfficiency(fromStagesJSON json: String?) -> Double? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var asleep = 0.0, total = 0.0
        for seg in arr {
            guard let s = (seg["start"] as? NSNumber)?.intValue,
                  let e = (seg["end"] as? NSNumber)?.intValue,
                  let stage = seg["stage"] as? String, e > s else { continue }
            let dur = Double(e - s)
            total += dur
            if stage != "wake" && stage != "awake" { asleep += dur }
        }
        return total > 0 && asleep > 0 ? asleep / total : nil
    }

    /// Re-derive stages from the raw streams for `[start, end]` (read under the strap `deviceId`),
    /// returning the encoded `stagesJSON`, or `nil` when the strap does NOT densely cover the window ,
    /// i.e. there isn't enough worn-night data to stage (a couple of stray samples must not trigger a
    /// degenerate `stageSession` that overwrites a good breakdown). ~1 sample / 2 min is the floor.
    /// Extracted from `editSleepTimes` so the post-sync self-heal reuses the exact density gate +
    /// staging. Stages OFF the main actor , Repository is `@MainActor` and a multi-hour window is tens of
    /// thousands of samples, which would otherwise freeze the UI.
    private func restageFromRaw(start: Int, end: Int) async -> String? {
        guard let store = await ensureStore() else { return nil }
        let lo = start - 3_600, hi = end + 3_600
        let grav = (try? await store.gravitySamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        let inWindowGravity = grav.lazy.filter { $0.ts >= start && $0.ts <= end }.count
        let windowSeconds = max(1, end - start)
        guard inWindowGravity >= max(20, windowSeconds / 120) else { return nil }
        let hr = (try? await store.hrSamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        let rr = (try? await store.rrIntervals(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        let resp = (try? await store.respSamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        // Opt-in experimental staging (Settings → Experimental · Sleep staging): when the user has flipped
        // the V2 flag on, re-stage with the cardiorespiratory recipe `SleepStagerV2`; otherwise the default
        // V1 `SleepStager`. Read once here off the actor; the switch is purely which engine runs over the
        // already-detected window , V1 stays the default and is untouched. (V7 Pillar 3b)
        let useV2 = PuffinExperiment.experimentalSleepV2Enabled
        let segs = await Task.detached(priority: .utility) {
            useV2
                ? SleepStagerV2.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
                : SleepStager.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
        }.value
        return AnalyticsEngine.encodeStages(segs)
    }

    /// Self-heal pass for the edit-races-sync bug. A night edited BEFORE the strap sync imported its raw
    /// streams got fabricated `SleepWindowReclip` stages (a trailing "awake" block) at edit time, and the
    /// `userEdited` flag then froze that breakdown against every later sync. Here , invoked from
    /// `analyzeRecent`, which runs after each sync backfill , we re-derive stages from the now-available
    /// raw over each edited night's LOCKED bounds and rewrite the stage breakdown ONLY, never the user's
    /// bed/wake correction. Idempotent: a night already staged from raw re-derives to the same JSON
    /// (equality-skip, no write); a night edited-too-early heals the moment its raw arrives; a true
    /// imported night (raw never dense) is left untouched (`restageFromRaw` returns nil). Reads/writes the
    /// COMPUTED source , the same one `analyzeRecent` reads edited rows from. Returns the (possibly
    /// refreshed) edited rows so the caller recomputes daily aggregates from the corrected stages.
    func selfHealEditedStages(from windowStart: Int, to windowEnd: Int) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        func editedRows() async -> [CachedSleepSession] {
            ((try? await store.sleepSessions(deviceId: computedDeviceId, from: windowStart,
                                             to: windowEnd, limit: 100_000)) ?? [])
                .filter { $0.userEdited }
        }
        let edited = await editedRows()
        guard !edited.isEmpty else { return [] }
        var healed = false
        for row in edited {
            // Re-derive over the LOCKED corrected window (effective onset → wake). Skip when the raw
            // isn't dense yet, or when the result already matches what's stored (steady state , no write).
            guard let newJSON = await restageFromRaw(start: row.effectiveStartTs, end: row.endTs),
                  newJSON != row.stagesJSON else { continue }
            let n = (try? await store.updateSleepStages(deviceId: computedDeviceId,
                                                        detectedStartTs: row.startTs,
                                                        stagesJSON: newJSON)) ?? 0
            if n > 0 { healed = true }
        }
        return healed ? await editedRows() : edited
    }

    // MARK: - Metric explorer reads (generic substrate)

    /// Daily series for any metric key from a given source ("my-whoop" / "apple-health").
    /// When `source` is the canonical WHOOP id, UNION the active strap so a series stored under a re-added
    /// strap's id ("whoop-<uuid>") still surfaces alongside the canonical history (deduped per day, active
    /// strap wins). Other sources (apple-health / xiaomi-band / lab-book) read that source verbatim.
    func series(key: String, source: String, days: Int = 4000) async -> [(day: String, value: Double)] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        let pts: [MetricPoint]
        if source == canonicalDeviceId {
            pts = await unionMetricSeries(store: store, key: key, from: from, to: to)
        } else {
            pts = (try? await store.metricSeries(deviceId: source, key: key, from: from, to: to)) ?? []
        }
        return pts.map { ($0.day, $0.value) }
    }

    // MARK: - Deep Timeline (full-day full-resolution viewer , #575/#574/#582)
    //
    // The Deep Timeline draws a single metric across a zoomable time window at the resolution the zoom
    // demands: a whole day reads COARSE SQL buckets (a worn 24h is ~86k 1 Hz HR rows , drawing all of
    // them is the #1 risk, so we never load raw at day scale), while a zoomed-in window reads the RAW
    // per-second rows so the user can inspect real beats. The adaptive choice lives here in the read
    // layer (NOT the view) so the chart only ever receives ~targetPoints points regardless of zoom.

    /// A metric the Deep Timeline can plot. HR is the always-present hero (adaptively downsampled);
    /// the rest are lower-frequency raw-sample streams shown where the strap offloaded them.
    enum TimelineMetric: String, CaseIterable, Identifiable, Sendable {
        case hr, hrv, spo2, skinTemp, respiration, motion
        var id: String { rawValue }

        /// User-facing pill label.
        var title: String {
            switch self {
            case .hr: return "Heart Rate"
            // #803: the .hrv series is a TRAILING-WINDOW rMSSD moving across the session (HRVAnalyzer
            // .rollingRmssd), not one opaque "HRV" figure and not raw R-R ms. Label it honestly so the
            // pill names what the chart actually plots.
            case .hrv: return "Windowed rMSSD"
            case .spo2: return "SpO₂"
            case .skinTemp: return "Skin Temp"
            case .respiration: return "Respiration"
            case .motion: return "Motion"
            }
        }
    }

    /// One Deep-Timeline read: the plotted points plus whether they came from raw seconds or coarse
    /// buckets (the view shows the resolution honestly) and the bucket width used.
    struct TimelineSeries: Sendable {
        var points: [TrendPoint]
        var isRaw: Bool
        var bucketSeconds: Int
        static let empty = TimelineSeries(points: [], isRaw: false, bucketSeconds: 0)
    }

    /// Pure adaptive-resolution decision: the bucket width (seconds) to read for a `[from, to]` window
    /// that should yield ABOUT `targetPoints` points. A bucket of 1 means "read raw per-second rows".
    ///
    /// span/targetPoints is the natural bucket width; we floor it at 1 s (raw) and round to a friendly
    /// step so adjacent zoom levels share bucket edges (no shimmer while panning). The whole point: a
    /// day-scale window (≈86 400 s) at ~600 target points picks a coarse ~150 s bucket (never raw), while
    /// a few-minute zoom drops to bucket 1 and reads the real seconds. Static + pure so it's unit-testable
    /// without a store or a clock.
    nonisolated static func timelineBucketSeconds(spanSeconds: Int, targetPoints: Int) -> Int {
        let span = max(1, spanSeconds)
        let target = max(1, targetPoints)
        let ideal = span / target
        guard ideal > 1 else { return 1 }      // zoomed in enough that raw seconds already fit the budget
        // Snap up to a friendly step so neighbouring zoom levels reuse bucket boundaries.
        let steps = [2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        for s in steps where s >= ideal { return s }
        return steps.last!
    }

    /// The trailing-window width (seconds) for the #803 windowed-rMSSD `.hrv` series, chosen from the
    /// visible span: a tight 2-minute rMSSD when zoomed in so short autonomic swings show, widening with
    /// the span (capped at 10 min) so a whole-night/day view stays a readable line rather than a jagged
    /// per-2-min trace. ~1/30 of the span, clamped to [120 s, 600 s]. Pure + static so it's unit-testable.
    nonisolated static func hrvRollingWindowSec(spanSeconds: Int) -> Int {
        let span = max(1, spanSeconds)
        return min(600, max(120, span / 30))
    }

    /// Deep-Timeline read facade. Returns ~`targetPoints` points for `metric` over `[from, to]` from
    /// `source` (defaults to the user's own strap), choosing raw seconds vs coarse buckets adaptively so
    /// the chart never draws ~86k points (the #575 day-scale risk). HR rides the existing COALESCE reads
    /// (`hrBuckets`/`hrSamples`) so a PPG-only WHOOP 5 day still renders its ppgHrSample series (#156/#172)
    /// , at day scale `hrBuckets` averages PPG into its buckets, and zoomed-in `hrSamples` returns the raw
    /// PPG-derived seconds; neither is empty for a PPG-only night. Other metrics read their raw sample
    /// tables (low frequency, no 86k risk) and bin to the same bucket grid when zoomed out.
    func timelineSeries(metric: TimelineMetric, from: Int, to: Int,
                        targetPoints: Int = 600, source: String? = nil) async -> TimelineSeries {
        guard to > from, let store = await ensureStore() else { return .empty }
        // Default (no explicit source) → the user's own strap, UNIONed with the canonical "my-whoop" so the
        // Deep Timeline renders whether the landed day's raw sits under the re-added strap or the canonical
        // history. An explicit source (a per-source page) reads that source verbatim. `unionIds` is one id
        // on a single-device install (byte-identical) and dedups raw by ts (active strap wins).
        let unionIds: [String] = source.map { [$0] } ?? importedReadIds
        let bucket = Self.timelineBucketSeconds(spanSeconds: to - from, targetPoints: targetPoints)
        let isRaw = bucket <= 1

        if metric == .hr {
            // Both HR paths COALESCE measured + ppgHrSample (#156) , preserved by delegating to the
            // store reads rather than re-querying. Day scale → SQL-aggregated buckets; zoomed-in → raw.
            if isRaw {
                // Read each source's raw seconds (off the WhoopStore actor), then hand the union to the
                // pure helper on a utility task so the dedup + sort + map (up to 200k 1 Hz rows) runs OFF
                // the main actor and can't beach-ball a dense day. Mirrors `restageFromRaw`.
                var perId: [[HRSample]] = []
                for id in unionIds {
                    perId.append((try? await store.hrSamples(deviceId: id, from: from, to: to, limit: 200_000)) ?? [])
                }
                let points = await Task.detached(priority: .utility) {
                    Self.dedupSortRawHr(perId)
                }.value
                return TimelineSeries(points: points, isRaw: true, bucketSeconds: 1)
            }
            var byStart: [Int: HRBucket] = [:]
            for id in unionIds {
                for b in (try? await store.hrBuckets(deviceId: id, from: from, to: to, bucketSeconds: bucket)) ?? [] where byStart[b.ts] == nil { byStart[b.ts] = b }
            }
            return TimelineSeries(points: byStart.values.sorted { $0.ts < $1.ts }.map {
                TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm)
            }, isRaw: false, bucketSeconds: bucket)
        }

        // Non-HR streams: read raw rows (these tables are far sparser than 1 Hz HR, so a day's worth is
        // safe to load) and, when zoomed out, downsample to the bucket grid for a clean line. The reads
        // run here (each `timelineRawMetric` awaits the store actor); the dedup + sort + downsample over
        // the union is handed to a utility task so it runs OFF the main actor on a dense window. Mirrors
        // `restageFromRaw`.
        var perId: [[TrendPoint]] = []
        for id in unionIds {
            perId.append(await timelineRawMetric(metric: metric, store: store, source: id, from: from, to: to))
        }
        let points = await Task.detached(priority: .utility) {
            Self.dedupSortDownsampleRaw(perId, isRaw: isRaw, bucketSeconds: bucket)
        }.value
        guard !points.isEmpty else { return TimelineSeries(points: [], isRaw: isRaw, bucketSeconds: bucket) }
        return TimelineSeries(points: points, isRaw: isRaw, bucketSeconds: isRaw ? 1 : bucket)
    }

    /// Raw points for a non-HR timeline metric, mapped to display units (skin temp → °C via raw/100,
    /// matching #156 centidegrees; HRV → per-RR instantaneous from RR ms; respiration/SpO₂/motion as the
    /// stored signal). Empty when the strap offloaded nothing for the window.
    private func timelineRawMetric(metric: TimelineMetric, store: WhoopStore, source: String,
                                   from: Int, to: Int) async -> [TrendPoint] {
        func pt(_ ts: Int, _ v: Double) -> TrendPoint {
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(ts)), value: v)
        }
        switch metric {
        case .hr:
            return []   // handled by the caller's HR path
        case .hrv:
            // #803: plot a TRAILING-WINDOW rMSSD that MOVES across the session, not raw R-R ms mislabelled
            // "HRV". Read the R-R rows (low frequency, safe to load for a window) and hand them to
            // HRVAnalyzer.rollingRmssd (the SAME range + Malik ectopic filtering the nightly path uses), so
            // each point is an honest windowed rMSSD (ms). A sparse/artifact-heavy window emits nothing
            // rather than a noisy spike. The `to - from` span chooses the window width: a 2-min rMSSD for a
            // zoomed-in look, widening with the visible span so a day-scale view stays readable. The thinning
            // stride keeps a 1 Hz R-R stream from emitting a point per beat.
            let rr = (try? await store.rrIntervals(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            let window = Self.hrvRollingWindowSec(spanSeconds: to - from)
            return HRVAnalyzer.rollingRmssd(rr: rr, windowSec: window, stepSec: max(1, window / 8))
                .map { pt($0.ts, $0.rmssd) }
        case .spo2:
            // The honest raw red/IR ratio proxy (#166: no calibrated %), shown as a unitless trend.
            let s = (try? await store.spo2Samples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            return s.compactMap { $0.ir > 0 ? pt($0.ts, Double($0.red) / Double($0.ir)) : nil }
        case .skinTemp:
            let s = (try? await store.skinTempSamples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            return s.map { pt($0.ts, Double($0.raw) / 100.0) }   // centidegrees → °C (#156)
        case .respiration:
            let s = (try? await store.respSamples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            return s.map { pt($0.ts, Double($0.raw)) }
        case .motion:
            // Gravity vector magnitude as a coarse movement signal (1 g at rest).
            let s = (try? await store.gravitySamples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            return s.map { pt($0.ts, ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot()) }
        }
    }

    /// Mean-bin an already-loaded raw point series onto a `bucketSeconds` grid (floor(ts/bucket)*bucket),
    /// ascending. The in-process twin of `hrBuckets` for the non-HR streams. Pure + static so it's testable.
    nonisolated static func downsampleToBuckets(_ points: [TrendPoint], bucketSeconds: Int) -> [TrendPoint] {
        let bucket = max(1, bucketSeconds)
        guard !points.isEmpty else { return [] }
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for p in points {
            let key = (Int(p.date.timeIntervalSince1970) / bucket) * bucket
            let acc = sums[key] ?? (0, 0)
            sums[key] = (acc.sum + p.value, acc.n + 1)
        }
        return sums.keys.sorted().map { key in
            let acc = sums[key]!
            return TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(key)),
                              value: acc.sum / Double(acc.n))
        }
    }

    /// Pure off-main post-processing for the zoomed-in (raw) HR Deep-Timeline path. Takes the per-source
    /// reads (`hrSamples` already ran off the WhoopStore actor) and does the heavy dedup + sort + map that
    /// would otherwise run on `@MainActor` and beach-ball a dense day (up to 200k 1 Hz rows). Dedup is
    /// "first id wins per ts" (active strap first in `unionIds`), then ascending by ts, then mapped to
    /// `TrendPoint`. Identical semantics to the in-line version it replaced. `nonisolated static` so it's
    /// callable from a `Task.detached` and unit-testable off the actor.
    nonisolated static func dedupSortRawHr(_ perId: [[HRSample]]) -> [TrendPoint] {
        var byTs: [Int: HRSample] = [:]
        for samples in perId {
            for s in samples where byTs[s.ts] == nil { byTs[s.ts] = s }
        }
        return byTs.values.sorted { $0.ts < $1.ts }.map {
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: Double($0.bpm))
        }
    }

    /// Pure off-main post-processing for the non-HR raw Deep-Timeline path. Takes the per-source raw point
    /// arrays (`timelineRawMetric` already ran its store reads), dedups by ts across the union (first id
    /// wins, preserving each source's read order), sorts ascending, and either returns the raw points
    /// (`isRaw`) or mean-bins them onto the `bucketSeconds` grid. Identical semantics to the in-line
    /// version it replaced , moved off `@MainActor` so a dense multi-hour window can't freeze the UI.
    /// `nonisolated static` so it's callable from a `Task.detached` and unit-testable off the actor.
    nonisolated static func dedupSortDownsampleRaw(_ perId: [[TrendPoint]], isRaw: Bool,
                                                   bucketSeconds: Int) -> [TrendPoint] {
        var raw: [TrendPoint] = []
        var seenTs = Set<Int>()
        for points in perId {
            for p in points {
                let ts = Int(p.date.timeIntervalSince1970)
                if seenTs.insert(ts).inserted { raw.append(p) }
            }
        }
        raw.sort { $0.date < $1.date }
        if isRaw { return raw }
        return downsampleToBuckets(raw, bucketSeconds: bucketSeconds)
    }

    // MARK: - Cross-source resolver (PR#196)

    /// Product-facing daily series for a metric across every COMPATIBLE source, freshest-wins. Use this
    /// on surfaces where the user expects the best available signal (Compare/Insights/Stress/Explore/
    /// Today); use `series(key:source:)` where a single source must be honoured verbatim. Precedence is
    /// explicit per `sourceCandidates`: imported WHOOP > NOOP-computed > declared-compatible Apple Health.
    func resolvedSeries(key: String, source preferredSource: String, days: Int = 4000) async -> MetricSeriesResolution {
        let candidates = Self.sourceCandidates(forKey: key, preferredSource: preferredSource,
                                               actualWhoopSource: deviceId)
        guard let store = await ensureStore() else {
            return MetricSeriesResolution(requestedSource: preferredSource, candidates: candidates, points: [])
        }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))

        // First candidate wins per day; later candidates only fill days no earlier one covered.
        var byDay: [String: ResolvedMetricPoint] = [:]
        for candidate in candidates {
            let rows = await resolvedRows(store: store, candidate: candidate, from: from, to: to)
            for row in rows where byDay[row.day] == nil {
                byDay[row.day] = ResolvedMetricPoint(day: row.day, value: row.value,
                                                     source: candidate.source, sourceKey: candidate.key)
            }
        }
        let points = byDay.values.sorted { $0.day < $1.day }
        return MetricSeriesResolution(requestedSource: preferredSource, candidates: candidates, points: points)
    }

    /// Read one candidate's rows for the window: its metricSeries, plus the matching DailyMetric column
    /// for any day the metricSeries doesn't carry (a Bluetooth-only WHOOP 5 user has values in the daily
    /// columns but not the long-format series). Ascending by day.
    ///
    /// The DailyMetric read uses a +1-day upper buffer (`Self.dayAfter(to)`). A night is keyed on its LOCAL
    /// WAKE day, so the row backing the SELECTED day's Rest can sort on the day AFTER the caller's `to`
    /// (a just-after-midnight wake, or a UTC+ user whose wake-day rolls a calendar day ahead of the
    /// requested bound). Without the buffer that banked row was excluded and Today fell back to the latest
    /// historical Rest (#614). The buffer only WIDENS the daily read; `byDay`'s metricSeries-first
    /// precedence is unchanged, so an imported series point still wins its day. Mirrors Android
    /// WhoopRepository.resolvedRows.
    private func resolvedRows(store: WhoopStore, candidate: MetricSourceCandidate,
                             from: String, to: String) async -> [(day: String, value: Double)] {
        let metricRows = (try? await store.metricSeries(deviceId: candidate.source, key: candidate.key,
                                                        from: from, to: to)) ?? []
        var byDay = Dictionary(metricRows.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        if let dailyRows = try? await store.dailyMetrics(deviceId: candidate.source,
                                                         from: from, to: Self.dayAfter(to)) {
            for row in dailyRows where byDay[row.day] == nil {
                if let value = Self.dailyColumn(key: candidate.key, day: row) { byDay[row.day] = value }
            }
        }
        return byDay.keys.sorted().compactMap { day in byDay[day].map { (day, $0) } }
    }

    /// The candidate (source, key) pairs to try for `key`, in precedence order, given the user's
    /// `preferredSource`. The strap's real id is `actualWhoopSource` (`deviceId`), so the computed
    /// sibling is `actualWhoopSource + "-noop"`.
    ///  • strap-preferred → [imported strap, computed strap, compatible Apple] (Apple only for vitals
    ///    that have a declared 1:1 mapping);
    ///  • Apple-preferred → [Apple] (+ computed strap ONLY for steps/active_kcal, which the strap
    ///    estimates and Apple may not carry);
    ///  • any other source → itself only (nutrition/mood are single-source by design).
    static func sourceCandidates(forKey key: String, preferredSource: String,
                                 actualWhoopSource: String) -> [MetricSourceCandidate] {
        let computedSource = actualWhoopSource + "-noop"
        func uniqued(_ cs: [MetricSourceCandidate]) -> [MetricSourceCandidate] {
            var seen = Set<MetricSourceCandidate>(); var out: [MetricSourceCandidate] = []
            for c in cs where !seen.contains(c) { seen.insert(c); out.append(c) }
            return out
        }

        if preferredSource == whoopSource || preferredSource == actualWhoopSource {
            // Active strap first (live/measured wins per day), then the CANONICAL "my-whoop" import + its
            // computed sibling so history banked under the canonical id before a re-add still resolves (the
            // union model). `uniqued` collapses these to one pair on a single-device install (active ==
            // canonical), so that path is byte-identical. Apple is the final cross-source fallback.
            var candidates = [
                MetricSourceCandidate(source: actualWhoopSource, key: key),
                MetricSourceCandidate(source: computedSource, key: key),
                MetricSourceCandidate(source: whoopSource, key: key),
                MetricSourceCandidate(source: whoopSource + "-noop", key: key),
            ]
            if let appleKey = appleCompatibleKey(forWhoopKey: key) {
                candidates.append(MetricSourceCandidate(source: appleHealthSource, key: appleKey))
            }
            return uniqued(candidates)
        }
        if preferredSource == appleHealthSource {
            var candidates = [MetricSourceCandidate(source: appleHealthSource, key: key)]
            // Health Connect is an Apple-equivalent body-metric source (Android only , harmless no-op on
            // iOS/Mac, which never write a "health-connect" series). Kept here so the resolver is
            // byte-identical to Android's, where it makes a Health-Connect-only weight history resolve in
            // Compare (#443). A real Apple export still wins per day; HC fills the rest.
            candidates.append(MetricSourceCandidate(source: healthConnectSource, key: key))
            if noopComputedCanFillAppleMetric(key) {
                candidates.append(MetricSourceCandidate(source: computedSource, key: key))
            }
            return uniqued(candidates)
        }
        return [MetricSourceCandidate(source: preferredSource, key: key)]
    }

    /// The Apple-Health series key that carries the SAME physiological quantity as a WHOOP key , used
    /// only for the declared-compatible vitals; nil means "no Apple equivalent, don't fall back to it".
    static func appleCompatibleKey(forWhoopKey key: String) -> String? {
        switch key {
        case "rhr":              return "resting_hr"
        case "hrv", "spo2", "resp_rate", "avg_hr", "max_hr", "in_bed_min", "active_kcal":
            return key
        case "sleep_total_min":  return "asleep_min"
        case "sleep_deep_min":   return "deep_min"
        case "sleep_rem_min":    return "rem_min"
        case "sleep_light_min":  return "core_min"
        default:                 return nil
        }
    }

    /// Whether the NOOP-computed strap source may fill an Apple-preferred metric. Only the two daily
    /// totals the strap genuinely estimates (steps, calories) , never a derived WHOOP score.
    private static func noopComputedCanFillAppleMetric(_ key: String) -> Bool {
        switch key {
        case "steps", "active_kcal": return true
        default:                     return false
        }
    }

    /// The Explore read path (#199). Like `series(key:source:)` but, for the strap source
    /// ("my-whoop"), falls back to the on-device COMPUTED dailies a Bluetooth-only WHOOP 5 user
    /// has (no CSV/Health import) , so Charge/Rest/Effort/Health metrics still resolve. Three layers,
    /// imported-wins per day:
    ///  1. the imported metricSeries under `deviceId` (a real WHOOP export);
    ///  2. the COMPUTED metricSeries under `computedDeviceId` , for keys written there but absent from
    ///     the DailyMetric columns (notably `sleep_performance`, IntelligenceEngine's Rest composite);
    ///  3. the merged daily metrics (`self.days`, imported ∪ computed) for keys with a DailyMetric
    ///     column , the same key→column map InsightsView.dailyOutcome / Android's dailyPick use,
    ///     extended to the full daily column set.
    /// Any OTHER source (apple-health / nutrition-csv / noop-mood) reads only its own series, unchanged.
    func exploreSeries(key: String, source: String, days: Int = 4000) async -> [(day: String, value: Double)] {
        guard source == "my-whoop" else { return await series(key: key, source: source, days: days) }
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))

        // day → value, lowest-priority source first; higher-priority sources overwrite per day so a
        // real import always wins over the computed strap value.
        var byDay: [String: Double] = [:]

        // Layer 3 (lowest): merged daily column for keys that have one. `self.days` is the published
        // imported ∪ computed daily cache (parameter `days` is the lookback window, not this).
        for d in self.days where byDay[d.day] == nil {
            if let v = Self.dailyColumn(key: key, day: d) { byDay[d.day] = v }
        }
        // Layer 2: computed metricSeries (covers sleep_performance, which has no daily column). UNION the
        // active strap's computed sibling + the canonical computed sibling (canonical first so the active
        // strap's value, applied last, wins per day).
        for id in computedReadIds.reversed() {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] { byDay[p.day] = p.value }
        }
        // Layer 1 (highest): the imported export's metricSeries. UNION active strap + canonical (canonical
        // first so the active strap's value wins per day).
        for id in importedReadIds.reversed() {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] { byDay[p.day] = p.value }
        }

        return byDay.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
    }

    /// The merged DailyMetric column backing an Explore metric key, for the days the imported/computed
    /// metricSeries doesn't cover (strap-only WHOOP 5 users). Mirrors InsightsView.dailyOutcome and
    /// Android's dailyPick, extended to every Explore "my-whoop" key that maps to a daily column.
    /// Also handles the Apple-compatible sleep aliases (asleep_min / deep_min / rem_min / core_min) the
    /// resolver may request when filling an Apple candidate from its daily columns. Keys with no daily
    /// column (avg_hr / max_hr …) return nil , they resolve from metricSeries only.
    ///
    /// `sleep_performance` (the Rest composite, 0–100) is NOT a stored column: IntelligenceEngine persists
    /// it as a metricSeries point. But a Bluetooth-only WHOOP 5 user , and, crucially, the SELECTED
    /// (just-synced) day before the heavy daily pass has projected the series , has the night's totals
    /// banked on the DailyMetric row while the metricSeries point is still missing. Without this case the
    /// resolver returned no Rest for that day and Today borrowed the latest historical value (#614). Derive
    /// it on the fly from the same banked totals via the single source of truth
    /// `AnalyticsEngine.Rest.composite(daily:)` , the SAME composite the series carries (what
    /// IntelligenceEngine projects) , so the day resolves to its own Rest. Consistency is left to the
    /// scorer's neutral default here (the daily row carries no regularity term). Mirrors Android
    /// WhoopRepository.dailyColumn / RestScorer.restFromDaily.
    ///
    /// Internal + nonisolated (not private) so the pure `EditMergePrecedenceTests` can exercise the #614
    /// derivation directly off the main actor, the same way Android's `internal fun dailyColumn` is
    /// unit-tested. No non-test caller outside this type.
    nonisolated static func dailyColumn(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery":         return d.recovery
        case "hrv":              return d.avgHrv
        case "rhr", "resting_hr": return d.restingHr.map(Double.init)
        case "strain":           return d.strain
        case "resp_rate":        return d.respRateBpm
        case "spo2":             return d.spo2Pct
        case "skin_temp":        return d.skinTempDevC
        case "sleep_total_min", "asleep_min": return d.totalSleepMin
        case "sleep_efficiency": return d.efficiency
        case "sleep_deep_min", "deep_min": return d.deepMin
        case "sleep_rem_min", "rem_min":   return d.remMin
        case "sleep_light_min", "core_min": return d.lightMin
        case "sleep_performance": return AnalyticsEngine.Rest.composite(daily: d)
        case "steps":            return d.steps.map(Double.init)
        case "active_kcal", "energy_kcal": return d.activeKcalEst
        default:                 return nil
        }
    }

    func availableKeys(source: String) async -> [String] {
        guard let store = await ensureStore() else { return [] }
        // For the canonical WHOOP source, UNION the keys present under the active strap too, so a re-added
        // strap's series keys still list alongside the canonical history's. Other sources read verbatim.
        guard source == canonicalDeviceId, deviceId != canonicalDeviceId else {
            return (try? await store.metricKeys(deviceId: source)) ?? []
        }
        var keys = Set<String>()
        for id in importedReadIds { keys.formUnion((try? await store.metricKeys(deviceId: id)) ?? []) }
        return keys.sorted()
    }

    /// Native journal answers live under this dedicated source id. The journal table has no
    /// `source` column (PK is (deviceId, day, question)), so writing native answers under the
    /// imported `deviceId` would let a CSV re-import silently overwrite them , and clears could
    /// then delete imported rows. A separate device id keeps the two streams independent.
    static let journalDeviceId = "noop-journal"

    /// Logged behaviours (imported WHOOP journal ∪ native noop-journal) for correlation insights.
    func journalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        var imported: [JournalEntry] = []
        for id in importedReadIds { imported += (try? await store.journalEntries(deviceId: id, from: from, to: to)) ?? [] }
        let native = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                      from: from, to: to)) ?? []
        return Self.mergeJournal(imported: imported, native: native)
    }

    /// Imported journal rows only (used by the logging card to adopt the export's exact question
    /// strings into the catalog, so logged and imported days group under one behaviour).
    func importedJournalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        var rows: [JournalEntry] = []
        for id in importedReadIds { rows += (try? await store.journalEntries(deviceId: id, from: from, to: to)) ?? [] }
        return rows
    }

    /// One day's native answers (question → answeredYes) for the logging card's chip state. A
    /// targeted read , the merged list carries no deviceId, so it can't distinguish native rows.
    func nativeJournalAnswers(day: String) async -> [String: Bool] {
        guard let store = await ensureStore() else { return [:] }
        let rows = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                    from: day, to: day)) ?? []
        return Dictionary(rows.map { ($0.question, $0.answeredYes) },
                          uniquingKeysWith: { _, last in last })
    }

    /// Union; the NATIVE row wins per (day, question) , the in-app answer is the user's most recent
    /// explicit action and stays editable, unlike the immutable imported history.
    nonisolated static func mergeJournal(imported: [JournalEntry], native: [JournalEntry]) -> [JournalEntry] {
        var byKey: [String: JournalEntry] = [:]
        for e in imported { byKey[e.day + "\u{1F}" + e.question] = e }
        for e in native { byKey[e.day + "\u{1F}" + e.question] = e }
        return byKey.values.sorted { ($0.day, $0.question) < ($1.day, $1.question) }
    }

    /// Write one native answer (day per the importer's wake-day convention).
    func saveJournalAnswer(day: String, question: String, answeredYes: Bool, notes: String? = nil) async {
        guard let store = await ensureStore() else { return }
        _ = try? await store.upsertJournal(
            [JournalEntry(day: day, question: question, answeredYes: answeredYes, notes: notes)],
            deviceId: Self.journalDeviceId)
    }

    /// Clear one native answer (never touches imported rows , scoped to the dedicated source id).
    func clearJournalAnswer(day: String, question: String) async {
        guard let store = await ensureStore() else { return }
        _ = try? await store.deleteJournal(deviceId: Self.journalDeviceId, day: day, question: question)
    }

    /// All workouts (Whoop + Apple Health + on-device detected bouts), newest first.
    ///
    /// Detected bouts are surfaced with an honest "Detected" badge so the user can see , and
    /// dismiss or re-label , a duplicate the auto-detector created (#107). Dismissed detected spans
    /// are filtered HERE so every consumer (Workouts screen, Today, Coach context) agrees: the engine
    /// re-derives the detected rows each run, so a plain delete would resurrect them; the dismissed
    /// span list is the durable "not a workout" record.
    func workoutRows(days: Int = 4000) async -> [WorkoutRow] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        // UNION the active strap + canonical (and their computed siblings) so workouts banked under the
        // canonical "my-whoop" before a re-add still show, alongside the re-added strap's live workouts.
        // De-dup identical same-source rows that appear under both union ids by natural key (the cross-SOURCE
        // dedup below only collapses strap-vs-Apple twins, not a row present in two strap namespaces).
        var rows: [WorkoutRow] = []
        for id in importedReadIds { rows += (try? await store.workouts(deviceId: id, from: lo, to: hi, limit: 5000)) ?? [] }
        for id in computedReadIds { rows += (try? await store.workouts(deviceId: id, from: lo, to: hi, limit: 5000)) ?? [] }
        rows += (try? await store.workouts(deviceId: "apple-health", from: lo, to: hi, limit: 5000)) ?? []
        // Imported lifting sessions (Hevy / Liftosaur) live under their own "lifting" source.
        rows += (try? await store.workouts(deviceId: "lifting", from: lo, to: hi, limit: 5000)) ?? []
        rows = Self.dedupWorkoutsByNaturalKey(rows)
        let spans = WorkoutSource.parseDismissedSpans(dismissedDetectedSpans)
        // #687: collapse the SAME activity tracked live under the strap AND imported from Health Connect /
        // Apple Health into one richer entry , they sit under different sources so without this they show
        // as two sessions. Dedup runs on the dismissed-filtered set, before the final newest-first sort.
        let filtered = rows.filter { !WorkoutSource.isDismissed($0, spans: spans) }
        // Workouts & GPS test mode: when on, run the dedup twin which returns the BYTE-IDENTICAL kept list
        // plus a trace line per collapsed cross-source pair, tagged `.workouts`. Zero-cost when off (the gate
        // is one UserDefaults bool read inside emitWorkouts), and the kept list equals dedupCrossSource(...)
        // exactly, so the workout list the screen shows is unchanged.
        let deduped: [WorkoutRow]
        if TestCentre.active(.workouts), workoutsLog != nil {
            let (kept, trace) = WorkoutSource.dedupCrossSourceTrace(filtered)
            for line in trace { emitWorkouts(line) }
            deduped = kept
        } else {
            deduped = WorkoutSource.dedupCrossSource(filtered)
        }
        let visible = deduped.sorted { $0.startTs > $1.startTs }
        return await reconcileWorkoutHrWithTrace(visible, store: store)
    }

    /// DISPLAY-ONLY: reconcile each workout's shown Avg/Max HR with the strap trace that actually drives
    /// its graph / zones / effort (#77, #499). The detail screen always charts (`workoutHrBuckets`) and
    /// zone-bins (`workoutZoneMinutes`) the strap's own ~1 Hz samples over `[startTs, endTs]`; the
    /// displayed Avg HR comes from the stored `avgHr`. Those can DIVERGE , a hand-edited Avg (128→139)
    /// changes the number but not the trace, so the average no longer matches the graph/zones/effort
    /// (#499). Here the stored field defers to the trace whenever the trace is present:
    ///
    ///  - STRAP-NATIVE rows (`manual` / detected `<id>-noop`) are charted/zoned/scored straight from this
    ///    strap trace, so their Avg HR is ALWAYS recomputed as the true mean of those samples (and Max →
    ///    true peak) , a manual edit can no longer drift them out of agreement with the graph.
    ///  - IMPORTED rows (Apple Health / Health Connect / Whoop CSV) carry their OWN avg/max; we only FILL
    ///    them when nil (and the strap happened to be worn), never overriding a real imported value.
    ///
    /// Requires `minSamples` (~1 min) so stray samples can't fabricate an average, and caps the per-row
    /// HR reads so a huge history can't jank first paint. NEVER persisted , a read-time projection of the
    /// trace (the workout PK upsert would wipe it anyway), recomputed on every load so display == graph
    /// == zones == effort by construction. Kotlin twin: `WhoopRepository.fillWorkoutHrFromStrap`.
    private func reconcileWorkoutHrWithTrace(_ rows: [WorkoutRow], store: WhoopStore,
                                             minSamples: Int = 60, cap: Int = 300) async -> [WorkoutRow] {
        // #833 (on-open freeze): this used to run a SEQUENTIAL per-row loop, each awaiting one
        // `store.hrSamples(.., limit: 8000)` then reducing up to 8000 ints SYNCHRONOUSLY on the @MainActor
        // (sum + max), for up to `cap` rows. On a deep history that beach-balled first paint. Two changes,
        // both output-preserving: (1) the eligible rows' reads run with BOUNDED concurrency (chunks of
        // `readChunk`) so the single-connection store isn't swamped, and (2) the per-row sum/max moved OFF
        // the main actor into the `nonisolated static` `reduceWorkoutHr`. Eligibility + the `cap` budget are
        // resolved FIRST in row order (identical to the old loop: budget is spent on eligible rows top-down
        // and reads stop once it hits 0), so exactly the same rows are read and the result is byte-identical.
        let readChunk = 8

        // Phase 1 , resolve eligibility + spend the `cap` budget in ORIGINAL row order, exactly as the old
        // sequential loop did. Only these indices get a trace read; everything else passes through verbatim.
        // (Strap-native is recomputed in Phase 3 from the same `classify`, so it isn't carried here.)
        var budget = cap
        var eligibleIndices: [Int] = []
        for (i, row) in rows.enumerated() {
            let cls = WorkoutSource.classify(row.source)
            let strapNative = cls == .manual || cls == .detected
            guard row.endTs > row.startTs, budget > 0, strapNative || row.avgHr == nil else { continue }
            budget -= 1
            eligibleIndices.append(i)
        }

        // Phase 2 , read each eligible window with BOUNDED concurrency (chunks of `readChunk`) and reduce it
        // OFF the main actor, then return only PLAIN Ints (index, avg, peak) from the child tasks. Keeping the
        // `WorkoutRow` build out of the group means only Sendable scalars cross the task boundary; the row is
        // rebuilt on the main actor in Phase 3. The samples are the very ones the graph + zones + effort use
        // (strap deviceId, COALESCEd PPG fallback). Keyed by row index so reassembly stays in original order.
        var reduced: [Int: (avg: Int, peak: Int)] = [:]
        for chunkStart in stride(from: 0, to: eligibleIndices.count, by: readChunk) {
            let chunk = eligibleIndices[chunkStart..<min(chunkStart + readChunk, eligibleIndices.count)]
            await withTaskGroup(of: (index: Int, avg: Int, peak: Int)?.self) { group in
                for idx in chunk {
                    let startTs = rows[idx].startTs
                    let endTs = rows[idx].endTs
                    group.addTask { [deviceId] in
                        let samples = (try? await store.hrSamples(deviceId: deviceId,
                                                                  from: startTs, to: endTs,
                                                                  limit: 8000)) ?? []
                        guard samples.count >= minSamples else { return nil }
                        // Sum + max over up to 8000 ints , off the @MainActor (the freeze fix).
                        let (avg, peak) = Repository.reduceWorkoutHr(samples)
                        return (index: idx, avg: avg, peak: peak)
                    }
                }
                for await result in group {
                    if let r = result { reduced[r.index] = (avg: r.avg, peak: r.peak) }
                }
            }
        }

        // Phase 3 , reassemble in ORIGINAL order. For an eligible row that cleared `minSamples` apply the
        // off-main reduction (strap-native → trace IS the source: override avg + max; imported → fill avg,
        // keep imported max). Every other row passes through verbatim. Byte-identical to the old loop's row.
        return zip(rows.indices, rows).map { i, row in
            guard let r = reduced[i] else { return row }
            let cls = WorkoutSource.classify(row.source)
            let strapNative = cls == .manual || cls == .detected
            let newMax = strapNative ? r.peak : (row.maxHr ?? r.peak)
            return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                              source: row.source, durationS: row.durationS, energyKcal: row.energyKcal,
                              avgHr: r.avg, maxHr: newMax, strain: row.strain, distanceM: row.distanceM,
                              zonesJSON: row.zonesJSON, notes: row.notes)
        }
    }

    /// #833: the per-workout HR reduction (mean bpm → rounded Int, peak bpm), pulled OUT of the @MainActor
    /// reconcile loop. `nonisolated static` so a `withTaskGroup` child task runs it OFF the main actor , a
    /// dense workout's up-to-8000 1 Hz samples no longer sum/max on the actor that drives SwiftUI. Pure +
    /// unit-testable. Byte-identical to the old inline `reduce(0,+)` / `max()`: same rounding, same peak.
    /// Caller guarantees `samples` is non-empty (the `minSamples` gate), so the mean divisor is never zero.
    nonisolated static func reduceWorkoutHr(_ samples: [HRSample]) -> (avg: Int, peak: Int) {
        var sum = 0
        var peak = 0
        for s in samples {
            sum += s.bpm
            if s.bpm > peak { peak = s.bpm }
        }
        let avg = Int((Double(sum) / Double(samples.count)).rounded())
        return (avg, peak)
    }

    // MARK: - Workout editing (manual add/edit · relabel · dismiss · delete)
    //
    // Manual workouts live under the strap source (deviceId == `deviceId`, source "manual") , the same
    // place v1.67's live-tracked sessions already land (AppModel.endWorkout). Detected bouts live under
    // the computed `computedDeviceId` with sport "detected" and are wiped + re-derived each engine run,
    // so the only durable way to keep one hidden after a re-detect is the dismissed-span list below.

    /// The persisted dismissed detected spans ("startTs:endTs"). Read straight off UserDefaults so the
    /// read path and the write path share one source of truth (the engine never sees this , it always
    /// re-derives; only the read filter and these mutators consult it).
    private var dismissedDetectedSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: WorkoutSource.dismissedDefaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: WorkoutSource.dismissedDefaultsKey) }
    }

    /// Persist a retroactive / edited manual workout under the strap source. `replacing` is the row the
    /// edit started from:
    ///  - editing a DETECTED bout ("Edit details…") replaces it with this manual row , the detected
    ///    original is dismissed durably so the re-detector doesn't bring it back (else both would show);
    ///  - editing a MANUAL row whose natural key (startTs/sport) changed deletes the stale strap row
    ///    first (the (deviceId, startTs, sport) PK upsert would otherwise orphan it);
    ///  - an IMPORTED row is never passed here as `replacing` (duplicating one is a pure add), so its
    ///    history is never touched.
    func saveManualWorkout(_ row: WorkoutRow, replacing old: WorkoutRow? = nil) async {
        guard let store = await ensureStore() else { return }
        if let old, WorkoutSource.classify(old.source) == .detected {
            await dismissDetected(old)
        } else if let old, old.startTs != row.startTs || old.sport != row.sport {
            _ = try? await store.deleteWorkouts(deviceId: deviceId, sport: old.sport,
                                                from: old.startTs, to: old.startTs)
        }
        _ = try? await store.upsertWorkouts([row], deviceId: deviceId)
    }

    /// Re-label a detected bout: copy it to a manual strap row with the chosen sport, then delete the
    /// detected original. This survives analyzeRecent , the engine wipes + re-derives only sport
    /// "detected" rows under the computed id AND skips any re-derived bout overlapping a real strap
    /// workout, which this copy now is , so the same session is never re-created as a duplicate. (#107)
    func relabelDetected(_ row: WorkoutRow, sport: String) async {
        guard let store = await ensureStore() else { return }
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let manual = WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: trimmed, source: "manual",
                                durationS: row.durationS, energyKcal: row.energyKcal,
                                avgHr: row.avgHr, maxHr: row.maxHr, strain: row.strain,
                                distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes)
        _ = try? await store.upsertWorkouts([manual], deviceId: deviceId)
        _ = try? await store.deleteWorkouts(deviceId: computedDeviceId, sport: "detected",
                                            from: row.startTs, to: row.startTs)
    }

    /// Dismiss a DETECTED bout the user says isn't a workout. Records its span in the durable dismissed
    /// list (so a re-detect that recreates the same span stays hidden) AND deletes the current row so it
    /// disappears immediately. Idempotent: a span already present isn't duplicated. (#107)
    func dismissDetected(_ row: WorkoutRow) async {
        guard WorkoutSource.classify(row.source) == .detected else { return }
        let token = WorkoutSource.dismissedToken(for: row)
        var spans = dismissedDetectedSpans
        if !spans.contains(token) { spans.append(token); dismissedDetectedSpans = spans }
        guard let store = await ensureStore() else { return }
        _ = try? await store.deleteWorkouts(deviceId: computedDeviceId, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
    }

    /// Delete ONE workout by natural key. The read model has no deviceId, so reconstruct it from the
    /// source: detected rows live under the computed id (and also get their span dismissed so they don't
    /// come back); everything else the screen can delete (manual) lives under the strap id.
    func deleteWorkout(_ row: WorkoutRow) async {
        if WorkoutSource.classify(row.source) == .detected { await dismissDetected(row); return }
        guard let store = await ensureStore() else { return }
        _ = try? await store.deleteWorkouts(deviceId: deviceId, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
    }

    // MARK: - Auto-detect workouts (opt-in MVP) , the "Looks like a workout?" Today prompt
    //
    // Pure read + suggestion path for the opt-in `AutoWorkoutDetector`. This is SEPARATE from the
    // gravity-gated detected-bouts pipeline above (which writes "detected" rows under the computed id):
    // nothing here is ever persisted as a workout until the user taps Save, and a dismissed suggestion
    // is remembered in its OWN durable span list (distinct key from `dismissedDetected`) so it never
    // re-prompts. The detector + thresholds are byte-mirrored in the Android twin.

    /// Dismissed AUTO-DETECT spans ("startSec:endSec"), kept apart from the gravity detector's
    /// `dismissedDetected` list so the two features never cross-suppress each other.
    private static let autoDetectDismissedKey = "workouts.autoDetectDismissed"
    private var autoDetectDismissedSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.autoDetectDismissedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoDetectDismissedKey) }
    }

    /// Token for one auto-detect span (matches the detector's integer seconds).
    private func autoDetectToken(_ w: DetectedWorkout) -> String { "\(w.startSec):\(w.endSec)" }

    /// Hard cap on the dismissed-span list , a backstop so the UserDefaults array can't grow without
    /// bound even in pathological use. 200 most-recent (by span END) is far more than detection's ~2-day
    /// window can ever re-surface; the age prune below normally keeps it much shorter. Mirrors Android.
    private static let autoDetectDismissedMax = 200
    /// Spans whose END is older than this many seconds can never be re-suggested (detection only scans
    /// the last ~2 days), so we drop them. 30 days, matching the Android twin byte-for-byte.
    private static let autoDetectDismissedMaxAgeSec = 30 * 86_400

    /// Parse the END time (seconds) out of a "startSec:endSec" token; nil if malformed.
    private func autoDetectTokenEnd(_ token: String) -> Int? {
        guard let colon = token.lastIndex(of: ":") else { return nil }
        return Int(token[token.index(after: colon)...])
    }

    /// Prune the dismissed-span list: drop spans whose END is older than ~30 days (they can never be
    /// re-suggested anyway), then hard-cap to the `autoDetectDismissedMax` most-recent (by END) as a
    /// backstop. Malformed tokens are kept (treated as newest) so we never silently lose data on a
    /// parse miss. Byte-mirrored in the Android `AutoWorkoutPrefs.prune`.
    private func prunedAutoDetectSpans(_ spans: [String], now: Int) -> [String] {
        let cutoff = now - Self.autoDetectDismissedMaxAgeSec
        // Drop anything that aged out; an unparseable token survives the age filter.
        let fresh = spans.filter { token in
            guard let end = autoDetectTokenEnd(token) else { return true }
            return end >= cutoff
        }
        guard fresh.count > Self.autoDetectDismissedMax else { return fresh }
        // Over the cap , keep the most-recent by END (unparseable sort as newest). Sort indices so we
        // preserve the original list order among the kept entries and never collapse equal tokens.
        let keepIdx = Set(fresh.indices
            .sorted { (autoDetectTokenEnd(fresh[$0]) ?? .max) > (autoDetectTokenEnd(fresh[$1]) ?? .max) }
            .prefix(Self.autoDetectDismissedMax))
        return fresh.indices.filter { keepIdx.contains($0) }.map { fresh[$0] }
    }

    /// Run the opt-in detector over the last `daysBack` days of HR and return the single best
    /// candidate to suggest , newest first , that is NOT already saved and NOT previously dismissed.
    /// Returns nil when the toggle is off, there's nothing to suggest, or detection finds nothing.
    /// PURE READ: never writes a workout. The window scans from `daysBack` days ago to now.
    func autoDetectCandidate(daysBack: Int = 2) async -> DetectedWorkout? {
        guard PuffinExperiment.autoDetectWorkoutsEnabled else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let from = now - daysBack * 86_400
        let samples = await hrSamples(from: from, to: now, limit: 200_000)
        guard samples.count >= 2 else { return nil }
        let hr = samples.map { (ts: $0.ts, bpm: $0.bpm) }

        // Resting HR: most recent nightly RHR in range, else the detector's own default (60).
        let restingBpm = days.last(where: { $0.restingHr != nil })?.restingHr

        // Exclude every already-saved workout window (any source , strap, manual, imported, detected).
        let saved = await workoutRows()
        let savedSpans = saved.map { SavedWorkoutSpan(startSec: $0.startTs, endSec: $0.endTs) }

        // Workouts & GPS test mode: when on, run the diagnostic twin which returns the SAME candidates
        // detect(...) does (it reuses detect verbatim) plus the inputs / thresholds / per-window why trace,
        // tagged `.workouts`. Zero-cost when off: the gate is one UserDefaults bool read inside emitWorkouts,
        // and detectTrace is only called on that branch, so the default path runs the untraced detect.
        let candidates: [DetectedWorkout]
        if TestCentre.active(.workouts), workoutsLog != nil {
            let (results, trace) = AutoWorkoutDetector.detectTrace(
                hr: hr, restingBpm: restingBpm, motion: nil, savedSpans: savedSpans, path: "autoDetect")
            for line in trace { emitWorkouts(line) }
            candidates = results
        } else {
            candidates = AutoWorkoutDetector.detect(hr: hr, restingBpm: restingBpm,
                                                    motion: nil, savedSpans: savedSpans)
        }
        // Drop anything the user already dismissed, then take the most recent.
        let dismissed = Set(autoDetectDismissedSpans)
        return candidates
            .filter { !dismissed.contains(autoDetectToken($0)) }
            .max(by: { $0.startSec < $1.startSec })
    }

    /// SAVE a suggested window as a manual-style "Workout" (generic sport , we don't claim a sport we
    /// didn't classify). Built through the same `WorkoutSource.buildManualRow` the manual sheet uses, so
    /// it persists exactly like a hand-entered session under the strap source. After saving, the screen
    /// re-queries (the new saved span now excludes this window from re-suggestion).
    @discardableResult
    func saveDetectedWorkout(_ w: DetectedWorkout) async -> Bool {
        let durationMin = max(1, w.durationMin)
        let start = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        guard let row = WorkoutSource.buildManualRow(start: start, durationMin: durationMin,
                                                     sport: "Workout", avgHr: w.avgBpm,
                                                     energyKcal: nil) else { return false }
        await saveManualWorkout(row)
        return true
    }

    /// DISMISS a suggested window: record its span durably so it never re-prompts. Idempotent.
    /// Prunes the stored list on every add (drop spans older than ~30 days + hard-cap to 200 most-recent)
    /// so it can never grow unbounded. Byte-mirrored in the Android `AutoWorkoutPrefs.dismiss`.
    func dismissDetectedSuggestion(_ w: DetectedWorkout) {
        let token = autoDetectToken(w)
        var spans = autoDetectDismissedSpans
        guard !spans.contains(token) else { return }
        spans.append(token)
        autoDetectDismissedSpans = prunedAutoDetectSpans(spans, now: Int(Date().timeIntervalSince1970))
    }

    // MARK: - Workout detail (read-only helpers, additive) , #410
    //
    // The workout-detail screen needs two reads over a single session's [startTs, endTs] window:
    // a downsampled HR curve (for the ChartCard) and the raw HR samples binned into zone-minutes
    // (for the zones bar). Both reuse the existing HR reads; they're thin convenience wrappers that
    // keep the bucket size / sample cap consistent with the rest of the app and give the view one
    // call site to await. NEVER mutate , pure reads.

    /// Downsampled HR over a workout window for the detail HR-curve. A short session wants a finer
    /// bucket than the Today 24h chart (300 s would flatten a 30-min run to ~6 points), so the bucket
    /// scales with duration: ~120 buckets across the window, floored at 15 s and capped at 300 s.
    func workoutHrBuckets(from: Int, to: Int) async -> [HRBucket] {
        guard to > from else { return [] }
        let span = to - from
        let bucket = max(15, min(300, span / 120))
        return await hrBuckets(from: from, to: to, bucketSeconds: bucket)
    }

    /// Raw HR samples binned into per-zone MINUTES for a workout window, using the age-derived
    /// (Tanaka) %HRmax zones , the same display zone model `WorkoutsView` already uses for imported
    /// zone percentages, but computed here from the strap's own samples so a session WITHOUT imported
    /// `zonesJSON` still gets a real time-in-zone split. Returns nil when the window carries no HR (so
    /// the view shows nothing rather than five empty bars). `age <= 0` falls back to a 30 y default ,
    /// the zones are approximate either way and clearly labelled as such in the UI.
    func workoutZoneMinutes(from: Int, to: Int, age: Int) async -> [Double]? {
        guard to > from else { return nil }
        let samples = await hrSamples(from: from, to: to)
        guard !samples.isEmpty else { return nil }
        let zoneSet = HRZones.zones(age: age > 0 ? Double(age) : 30)
        let tiz = HRZones.timeInZone(samples, zoneSet: zoneSet)
        let minutes = tiz.seconds.map { $0 / 60.0 }
        return minutes.contains(where: { $0 > 0 }) ? minutes : nil
    }

    /// Apple Health daily aggregates (steps/energy/vo2/hr).
    func appleDailyRows(days: Int = 4000) async -> [AppleDaily] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        return (try? await store.appleDaily(
            deviceId: "apple-health",
            from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
            to: Self.dayString(now.addingTimeInterval(86_400)))) ?? []
    }

    /// Shared formatter , created once. Hot read path (called per series window / refresh);
    /// allocating a DateFormatter per call was a measurable waste. Read-only use is thread-safe.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }

    /// The "yyyy-MM-dd" day one calendar day AFTER `day`, or `day` verbatim when it isn't a parseable
    /// ISO date (e.g. a wide-open sentinel already past every real day, so no buffer is needed). Backs the
    /// +1-day daily read buffer in `resolvedRows` so a wake-day-keyed night that sorts just past the
    /// requested upper bound still resolves the selected day (#614). Mirrors Android
    /// WhoopRepository.bufferDayAfter.
    static func dayAfter(_ day: String) -> String {
        guard let d = dayFormatter.date(from: day),
              let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: d)
        else { return day }
        return dayFormatter.string(from: next)
    }
}

private extension DailyMetric {
    /// A copy of self where every nil field is backfilled from `fallback`. Used by the field-by-field
    /// daily merge so an imported export keeps its own values while a computed row fills the gaps it
    /// doesn't carry (e.g. on-device Charge / skin-temp deviation / activity totals).
    func fillingNilFields(from fallback: DailyMetric) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: totalSleepMin ?? fallback.totalSleepMin,
            efficiency: efficiency ?? fallback.efficiency,
            deepMin: deepMin ?? fallback.deepMin,
            remMin: remMin ?? fallback.remMin,
            lightMin: lightMin ?? fallback.lightMin,
            disturbances: disturbances ?? fallback.disturbances,
            restingHr: restingHr ?? fallback.restingHr,
            avgHrv: avgHrv ?? fallback.avgHrv,
            recovery: recovery ?? fallback.recovery,
            strain: strain ?? fallback.strain,
            exerciseCount: exerciseCount ?? fallback.exerciseCount,
            spo2Pct: spo2Pct ?? fallback.spo2Pct,
            skinTempDevC: skinTempDevC ?? fallback.skinTempDevC,
            respRateBpm: respRateBpm ?? fallback.respRateBpm,
            steps: steps ?? fallback.steps,
            activeKcalEst: activeKcalEst ?? fallback.activeKcalEst
        )
    }

    /// A copy of self where the SLEEP fields are overridden by `source` , used by the H5 edit-merge so a
    /// hand-edited night's computed sleep figures win over the import for that day (#509). Only the sleep
    /// columns move; every other field (recovery/strain/HRV/RHR/activity/in-sleep vitals) is left as-is, so
    /// the import still wins for non-sleep metrics on the edited day.
    func takingSleepFields(from source: DailyMetric) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: source.totalSleepMin,
            efficiency: source.efficiency,
            deepMin: source.deepMin,
            remMin: source.remMin,
            lightMin: source.lightMin,
            disturbances: source.disturbances,
            restingHr: restingHr,
            avgHrv: avgHrv,
            recovery: recovery,
            strain: strain,
            exerciseCount: exerciseCount,
            spo2Pct: spo2Pct,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateBpm,
            steps: steps,
            activeKcalEst: activeKcalEst
        )
    }
}
