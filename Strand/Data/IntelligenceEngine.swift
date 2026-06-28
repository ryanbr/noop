import Foundation
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// On-device "intelligence": computes recovery / day-strain / sleep from the raw strap streams using
/// the same model shape WHOOP uses (HRV vs personal baseline ~60%, resting HR ~20%, sleep ~15%,
/// respiration ~5%; strain 0–21 from cardiovascular load). This is what makes NOOP independent of
/// WHOOP's cloud — for any day the strap collected raw data with NOOP connected, NOOP scores it
/// itself rather than relying on the values WHOOP computed in the imported CSV.
@MainActor
final class IntelligenceEngine: ObservableObject {
    private let repo: Repository
    private let profile: ProfileStore
    private let deviceId: String

    @Published var results: [Computed] = []      // newest first
    @Published var computing = false
    @Published var note: String?

    /// Who supplies the dashboard headline for a By-Day row. The By-Day card always shows NOOP's OWN
    /// on-device numbers, but the WHOLE-DASHBOARD value for the same day can come from an IMPORTED row
    /// that won the per-day merge (imports win field-by-field over computed — see Repository.mergeDaily).
    /// We resolve the REAL provenance so the card's badge tells a strap-scored night apart from an
    /// imported one, instead of always claiming "NOOP-computed". (Sleep overhaul §2.6 honesty fix.)
    enum DaySource: Equatable {
        /// NOOP scored this day itself from the raw strap streams; no import covers it.
        case computed
        /// A WHOOP export covers this day and wins the dashboard merge.
        case whoopImport
        /// An Apple Health import covers this day and wins the dashboard merge.
        case appleHealth

        /// The badge shown on the By-Day card. Brand wording matches the rest of the app
        /// (SleepView "On-device"/"Whoop", Today "Apple Health"). NO em-dashes.
        var badge: String {
            switch self {
            case .computed:    return "On-device"
            case .whoopImport: return "Whoop"
            case .appleHealth: return "Apple Health"
            }
        }

        /// The short token for the per-day strap-log diagnostic (privacy-safe; no device ids leak).
        var logToken: String {
            switch self {
            case .computed:    return "computed"
            case .whoopImport: return "imported:whoop"
            case .appleHealth: return "imported:apple"
            }
        }

        /// Resolve a day's provenance from the imported day-key sets. A WHOOP export covering the day
        /// WINS the dashboard merge over our computed row (imports win field-by-field — Repository
        /// .mergeDaily), so it takes precedence; Apple Health is next; otherwise the day is purely
        /// computed. WHOOP-over-Apple matches the merge's source priority (whoopImport 0 < appleHealth 2
        /// in DailyMetricSource.vitalPriority). Pure + set-based so it's unit-tested directly and is the
        /// SAME logic `analyzeRecent` ships. Mirrors the Android `IntelligenceEngine.daySourceToken`. (§2.6)
        static func classify(day: String, importedWhoopDays: Set<String>,
                             appleHealthDays: Set<String>) -> DaySource {
            if importedWhoopDays.contains(day) { return .whoopImport }
            if appleHealthDays.contains(day) { return .appleHealth }
            return .computed
        }
    }

    /// One day's off-actor scan output (FIX 1). Carries the pure `AnalyticsEngine.DayResult` produced by
    /// the off-main scan loop plus the pre-computed RHR floor-vs-mean diagnostic line (#691) — computed
    /// inside the detached task from pure inputs so the main actor can replay it through the
    /// MainActor-bound `diagnosticSink` in the SAME per-day order. Deliberately NOT marked `Sendable`:
    /// its `AnalyticsEngine.DayResult` member isn't formally `Sendable` either, and the per-day loop ALREADY
    /// returned a `DayResult` across the `Task.detached` boundary under this project's `minimal` strict-
    /// concurrency setting (SWIFT_STRICT_CONCURRENCY: minimal, Swift 5 mode) — this wraps the same value
    /// type the same way, so it crosses the boundary identically.
    private struct DayScan {
        let result: AnalyticsEngine.DayResult
        let rhrLine: String?
        /// Sleep & Rest test-mode gate-trace + Rest sub-score lines for this day, collected off the main
        /// actor and replayed through `diagnosticSink` tagged `.sleep` in per-day order. Empty unless the
        /// Sleep mode is active (the gate is read once before the loop), so the default path is unchanged.
        let sleepTrace: [String]
        /// Steps test-mode raw-counter trace lines (5/MG cumulative @57 series + wrap-aware deltas + dropped
        /// deltas) for this day, collected off the main actor and replayed tagged `.steps` in per-day order.
        /// Empty unless the Steps mode is active (the gate is read once before the loop), so the default path
        /// is byte-identical: the trace recomputes the SAME wrap-aware sum analyzeDay already computed.
        let stepsTrace: [String]
    }

    struct Computed: Identifiable {
        let day: String
        let recovery: Double?
        let strain: Double?
        let sleepMin: Double?
        let hrv: Double?
        let rhr: Int?
        /// REAL provenance of the day's dashboard headline (computed vs an import that won the merge), so
        /// the By-Day badge is honest. Defaults to `.computed` (the engine always writes a computed row);
        /// set per day from the imported day-key sets resolved in `analyzeRecent`.
        var source: DaySource = .computed
        /// Charge (recovery) confidence for the day. Defaults `.solid` for a strap-scored night (the gauge
        /// already gates on the HRV baseline being usable); the Apple-Watch fold below sets this to the
        /// `WatchRecovery` confidence so a watch-only recovery reads "calibrating" until it has enough nights.
        var confidence: ScoreConfidence = .solid
        var id: String { day }
    }

    /// Optional sink for the per-day scoring diagnostic, fed line-by-line into the SAME shareable strap
    /// log the user already exports (PII-scrubbed by `LiveState.append(log:)`). Defaults to nil so the
    /// engine stays testable with no UI. Each line is a concise, counts-only summary ("sleep day=…
    /// totalSleepMin=… matched=… source=…") so the next bug report ships proof of what was computed per
    /// day, addressing the project's log-failures-not-successes blind spot and the data needed to settle
    /// "Rest repeats across days". (Sleep overhaul §2.5.)
    /// `AppModel` wires it to `live.append(log:domain:)`. Each line is a concise, counts-only summary,
    /// optionally tagged with the TestDomain so the Sleep/Battery emitters land under their profile tag.
    var diagnosticSink: ((String, TestDomain?) -> Void)?

    init(repo: Repository, profile: ProfileStore, deviceId: String) {
        self.repo = repo; self.profile = profile; self.deviceId = deviceId
    }

    /// Median of a list (0 when empty) — used to denoise the 7-day resting-HR for Fitness Age.
    static func medianOf(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// The per-day RHR floor-vs-mean diagnostic line (#691). NOOP's `floor` is the WHOOP-style resting
    /// HR — the lowest SUSTAINED 5-min in-bed level (SleepStager picks the min 5-min rolling-mean HR per
    /// session, the day takes the .min() across them) — whereas a "sleeping HR" app reports the night MEAN
    /// over the whole asleep span. The mean always sits at-or-above the floor, so NOOP reading lower is BY
    /// DESIGN, not a bug; logging both makes a "NOOP RHR is lower than my other app" report explainable
    /// from the strap log. `inBedBpms` is the bpm of every HR sample inside a matched in-bed session (the
    /// SAME span the floor came from, so the two numbers are directly comparable). Empty in-bed → nightMean
    /// is "nil". Counts/bpm only — no timestamps or PII. Pure so it's unit-tested directly and is the SAME
    /// line `analyzeRecent` ships. Byte-identical to the Android `rhrFloorMeanLogLine`.
    nonisolated static func rhrFloorMeanLogLine(day: String, floor: Int, inBedBpms: [Int]) -> String {
        let meanLog: String = inBedBpms.isEmpty ? "nil"
            : String(Int((Double(inBedBpms.reduce(0, +)) / Double(inBedBpms.count)).rounded()))
        return "rhr day=\(day) floor=\(floor) nightMean=\(meanLog) inBedSamples=\(inBedBpms.count) "
            + "(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)"
    }

    /// The Saturday on-or-before a "yyyy-MM-dd" local-day string — the weekly key Fitness Age writes to.
    static func saturdayKey(onOrBefore dayStr: String) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let fmt = DateFormatter(); fmt.calendar = cal; fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: dayStr) else { return dayStr }
        let back = cal.component(.weekday, from: d) % 7   // Sat(7)→0, Sun(1)→1 … Fri(6)→6
        let sat = cal.date(byAdding: .day, value: -back, to: d) ?? d
        return fmt.string(from: sat)
    }

    /// UserDefaults flag guarding the one-shot #313 full-history Effort rescore (below). Set once the
    /// pass completes so it never re-runs.
    static let effortRescoreFlagKey = "intelligence.effortRescore.v313.done"

    /// One-shot, on-upgrade FULL-history Effort rescore (#313 PART B). The Effort hero gauge + numbers
    /// moved from the old 0–21 axis to NOOP's own 0–100 axis. On-device computed rows since v2.6.1
    /// already store 0–100, but rows the engine computed on an OLDER build (capped at `maxDays` per run,
    /// so deep history was never revisited) may still hold 0–21 strain.
    ///
    /// The SAFE fix is to recompute strain FROM SOURCE for every day with raw HR — those regenerate at
    /// 0–100 with NO double-rescale risk — rather than a blind `strain*21→100` multiply that would
    /// double-rescale the large population already on 0–100 (→ ~0–476). We do that by running the normal
    /// `analyzeRecent` once with the `maxDays` cap lifted to the full history, then persist a flag so it
    /// runs exactly once. IMPORTED rows are never rewritten here (the engine only ever writes under the
    /// "-noop" computed source) — those are handled by re-import. A day already on 0–100 is recomputed
    /// from the same raw HR and lands on 0–100 again: UNCHANGED axis (verified by test).
    func runEffortRescoreIfNeeded(historyDays: Int = 4000) async {
        guard !UserDefaults.standard.bool(forKey: Self.effortRescoreFlagKey) else { return }
        await analyzeRecent(maxDays: historyDays)
        // Only mark done if the pass actually completed (wasn't skipped because another tick held the
        // `computing` lock). `computing` is false here once analyzeRecent's `defer` has run; a skipped
        // call returns with `note` unset by it. Use the lock state: if a concurrent run was in progress
        // the flag stays unset so the next launch retries — cheap, and correctness over a one-time cost.
        if !computing { UserDefaults.standard.set(true, forKey: Self.effortRescoreFlagKey) }
    }

    /// UserDefaults flag guarding the one-shot #547 implausible-timestamp DB heal (below). Set once the
    /// heal completes so it never re-runs.
    static let timestampHealFlagKey = "intelligence.timestampHeal.v547.done"

    /// #547 RE-POLLUTION re-arm: a one-shot heal isn't enough when a strap with a WANDERING clock keeps
    /// re-sending bad-dated records across syncs. Whenever a sync's ingest gate drops implausible records
    /// (the strap demonstrably has a bad clock THIS session), `BLEManager` sets this pending flag so the
    /// next analyze tick re-runs the purge — clearing any pollution that slipped in on an OLDER build whose
    /// gate was weaker, rather than permanently gating behind the one-shot `done` flag. Cleared once the
    /// re-heal runs. Pure UserDefaults so the BLE layer can set it without an engine reference.
    static let timestampHealPendingKey = "intelligence.timestampHeal.v547.pending"

    /// Mark the #547 heal as needing a re-run because a sync just dropped implausible (bad-clock) records.
    /// Called from `BLEManager.exitBackfilling` (no engine handle there); the next `runTimestampHealIfNeeded`
    /// honours it even after the one-shot `done` flag is set.
    static func requestTimestampReheal() {
        UserDefaults.standard.set(true, forKey: timestampHealPendingKey)
    }

    /// One-shot, on-upgrade heal of a database polluted by a bad-clock strap (#547, pikapik). The ingest
    /// gate now keeps garbage-timestamped records out, but a user who synced on an older build already has
    /// rows dated to scattered garbage (far-past, a bogus 2027, FUTURE dates) — which made one ~12h block
    /// re-attribute to every day (the repeated totalSleepMin=721 across many days) and a future row surface
    /// as the Today "last night" carry-over. This purges those rows ONCE, then rescores from the surviving
    /// real raw data so the genuine days recompute cleanly. Idempotent (a clean DB deletes nothing) and
    /// re-running is harmless, but a persisted flag skips it on every later launch. Runs BEFORE the normal
    /// `analyzeRecent` loop so the rescore it triggers operates on an already-cleaned DB.
    func runTimestampHealIfNeeded(historyDays: Int = 4000) async {
        // Run when the one-shot heal hasn't run yet OR a sync just flagged a re-heal (#547 re-pollution): a
        // wandering-clock strap re-sends bad-dated records across syncs, so a single on-upgrade pass can't
        // be the only line of defence. The pending flag is cleared below once the re-heal completes.
        let pending = UserDefaults.standard.bool(forKey: Self.timestampHealPendingKey)
        guard pending || !UserDefaults.standard.bool(forKey: Self.timestampHealFlagKey) else { return }
        guard let store = await repo.storeHandle() else { return }   // no store yet → retry next launch
        let result: WhoopStore.TimestampHealResult
        do {
            result = try await store.healImplausibleTimestamps()
        } catch {
            NSLog("IntelligenceEngine: timestamp heal (#547) FAILED — \(error); will retry next launch")
            return   // leave the flag unset so a transient failure retries
        }
        if result.didChange {
            diagnosticSink?("Heal(#547): purged \(result.rawRowsDeleted) raw + \(result.computedRowsDeleted) computed row(s) with implausible (bad-clock) timestamps; rescoring the real days.", nil)
            // Recompute the affected real days from the surviving raw rows so the polluted (e.g. 721)
            // blocks regenerate cleanly. The dashboard refresh happens inside analyzeRecent on persist.
            await analyzeRecent(maxDays: historyDays)
            // Only mark done once the rescore actually ran (wasn't skipped by a concurrent tick holding
            // the `computing` lock), so a skipped pass retries next launch — correctness over a one-time cost.
            guard !computing else { return }
        }
        UserDefaults.standard.set(true, forKey: Self.timestampHealFlagKey)
        // Clear the re-pollution request now that this re-heal has run — a future bad-clock sync re-arms it.
        UserDefaults.standard.set(false, forKey: Self.timestampHealPendingKey)
    }

    /// Compute on-device scores for each of the last `maxDays` that actually has raw HR data.
    /// Personal baselines (HRV / resting HR) are folded from the imported history, so even the first
    /// live night can be scored against your norm.
    func analyzeRecent(maxDays: Int = 21) async {
        guard !computing else { return }
        guard let store = await repo.storeHandle() else { note = "No on-device store yet."; return }
        guard let hrvCfg = Baselines.metricCfg["hrv"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let respCfg = Baselines.metricCfg["resp"],
              let skinCfg = Baselines.metricCfg["skin_temp"] else { return }

        computing = true
        defer { computing = false }

        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex,
                             stepTicksPerStep: profile.stepTicksPerStep)

        let maxHR = profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride) : nil
        let now = Int(Date().timeIntervalSince1970)
        // Device wall-clock offset (seconds east of UTC) for the sleep detector's daytime
        // false-sleep guard (#90): the stager places each window's center on the LOCAL clock
        // so only genuinely-daytime windows face the stricter nap bar. (Computed once; a DST
        // boundary inside the window is a negligible edge case for an hour-of-day band.)
        let tzOffset = TimeZone.current.secondsFromGMT()

        // ── Pass 1: analyse each offloaded night against the IMPORTED-ONLY baseline. For a BLE-only
        // user the imported daily rows are empty, so the HRV baseline isn't usable yet and recovery is
        // null here — but each night's avgHrv/restingHr are computed baseline-INDEPENDENTLY, so we
        // harvest them to SEED the baseline and re-score in pass 2. foldHistory winsorizes outliers.
        //
        // Read the imported rows DIRECTLY (deviceId is the imported id; computed rows live under the
        // sibling `-noop` id) over the full history, sorted chronologically — NOT `repo.days`, which is
        // the merged published cache (it pre-loads prior computed `-noop` rows and back-fills nil
        // imported HRV/RHR/resp fields from computed values). Using the merge contaminated this very
        // "imported-only" baseline with computed values and made the fold window depend on whichever
        // refresh last ran (4000 vs 120 days). This mirrors the Android port's `days(importedDeviceId)`.
        let hist = ((try? await store.dailyMetrics(deviceId: deviceId, from: "0000-01-01", to: "9999-12-31")) ?? [])
            .sorted { $0.day < $1.day }
        // HRV baseline honours the manual "Recalibrate baseline" epoch (noop.hrvBaselineEpoch); the
        // resting-HR baseline honours the Charge-wide sibling (noop.recoveryBaselineEpoch). Pass the
        // per-value "yyyy-MM-dd" day keys (parallel to the values) so foldHistory can drop every night
        // before the epoch. A 0 / absent epoch makes this byte-identical to the plain fold, so scoring is
        // unchanged until the user taps Recalibrate.
        let hrvBase1 = Baselines.foldHistory(hist.map { $0.avgHrv }, dayKeys: hist.map { $0.day }, cfg: hrvCfg)
        let rhrBase1 = Baselines.foldHistory(hist.map { $0.restingHr.map(Double.init) }, dayKeys: hist.map { $0.day },
                                             cfg: rhrCfg, baselineEpoch: Baselines.recoveryBaselineEpoch())
        let baselines1 = AnalyticsEngine.ProfileBaselines(hrv: hrvBase1, restingHR: rhrBase1)

        // Keep each night's small result (daily metrics + sessions), NOT the raw streams — every field
        // except recovery is baseline-independent, so pass 2 only re-scores the cheap recovery
        // composite. The hr/rr/resp/gravity arrays go out of scope each iteration (memory stays bounded).
        var scoredNights: [(daily: DailyMetric, strain: Double?, cachedSleep: [CachedSleepSession],
                            workouts: [ExerciseSession], nightlySkin: Double?,
                            sessionMotion: [Int: [Double]])] = []
        // Nightly values harvested in pass 1, keyed by day, to seed the pass-2 baseline.
        var nightlyHrvByDay: [String: Double?] = [:]
        var nightlyRhrByDay: [String: Double?] = [:]
        // On-device RSA respiration + wear-gated skin-temp means (baseline-independent), harvested to
        // seed resp/skin-temp baselines the same way avgHrv seeds the HRV baseline.
        var nightlyRespByDay: [String: Double?] = [:]
        var nightlySkinByDay: [String: Double?] = [:]

        // Device-registry snapshot for per-day owner resolution (invariant I2 — a day's scores come from
        // exactly ONE source). Read once before the loop: the paired-device list + the active id are
        // stable for the run. With only the seeded 'my-whoop' row paired (the default and every
        // single-WHOOP install) the active strap is `deviceId`, so `resolveDayOwner` below returns
        // `deviceId` for every day and the per-day reads are byte-identical to the pre-I2 behaviour.
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let regDevices = (try? registry.all()) ?? []
        let regActiveId = (try? registry.activeDeviceId()) ?? deviceId

        // Floor `now` to LOCAL midnight (#277) so each `dayStart` lands on a local-day boundary and the
        // day keys are LOCAL calendar days, consistent with the dashboard's local "today" lookup. A
        // west-of-UTC user's evening crosses midnight UTC; bucketing by UTC put it in the next UTC day,
        // which the local read never found (Toronto/UTC-4 report).
        let nowLocalMidnight = Self.midnightLocal(now, offsetSec: tzOffset)

        // ── Learned habitual midsleep (#547) ──────────────────────────────────
        // Compute the user's habitual midsleep ONCE per run from the trailing sleep history so the
        // main-night scored pick aligns to their REAL bedtime (a late/shift sleeper), not a fixed clock
        // band. Read the stored sleep sessions (imported WHOOP-export + computed "-noop") over the
        // analysis window, make one HistoryBlock per session keyed by the LOCAL calendar day of its
        // midpoint, and let the learner pick the longest block per day (so naps drop out automatically).
        // Returns nil under `habitualMinDays` of history → cold-start: every `analyzeDay`/`sleepEditedDaily`
        // call below stays on the overnight-band bonus. The same value threads into both seams so analytics
        // and the Sleep tab resolve to the identical block. (#547)
        let habitualMidsleepSec = await Self.computeHabitualMidsleep(
            store: store, importedId: deviceId, computedId: deviceId + "-noop",
            windowStart: nowLocalMidnight - maxDays * 86_400 - 30 * 3_600,
            windowEnd: now, offsetSec: tzOffset)

        // ── FIX 1 (main-actor jank): run the ENTIRE per-day enumeration OFF the main actor ───────────
        // Every `await store.…` read inside this loop has its continuation RESUME on the main actor
        // (the engine is `@MainActor`), so on a fresh-import 4000-day pass the ~32 000 read-resumes
        // monopolise the main actor for ~1 minute and SwiftUI can't render. The per-day reads + scoring
        // touch NO `@Published`/`repo`/`profile` state — only the captured immutable inputs, the
        // `WhoopStore` actor, the nonisolated `registry`, and the pure `resolveDayOwner` /
        // `bandSleepStateSamples` / `AnalyticsEngine.analyzeDay`. So we hoist the whole loop into ONE
        // `Task.detached(priority:.utility)` whose continuations resume OFF the main actor, then hop back
        // here only to fold the results into `@Published`-feeding state and `refresh()` once at the end.
        // The per-day SCORING ORDER, the `hr.count >= 200` skip, and the maxDays semantics are unchanged;
        // only the executor the reads resume on changes. Diagnostic (#691) lines are computed inside (pure
        // inputs) and returned so they can be replayed through `diagnosticSink` here, in the SAME order.
        let computedId = deviceId + "-noop"
        // Bind `deviceId` (a MainActor instance `let`) to a local Sendable `String` so the @Sendable
        // detached closure captures the VALUE, never `self` (which would be an isolation violation).
        let ownerFallbackId = deviceId
        // Sleep & Rest test mode (E5): read the zero-cost gate ONCE here (a single Bool) and capture it
        // into the detached loop. When false (the default), no per-day trace sink is built and analyzeDay
        // runs its byte-identical default path. When true, each day collects its gate-trace + Rest line,
        // replayed below through `diagnosticSink` tagged `.sleep` in per-day order.
        let sleepTraceActive = TestCentre.active(.sleep)
        // Steps test mode: read the zero-cost gate ONCE here (a single Bool) and capture it into the detached
        // loop. When false (the default), no raw-counter trace is built per day. When true, each day collects
        // the 5/MG cumulative @57 series + wrap-aware deltas + dropped deltas, replayed below tagged `.steps`.
        // The trace recomputes the SAME wrap-aware sum analyzeDay already did, so the steps total is unchanged.
        let stepsTraceActive = TestCentre.active(.steps)
        let scanned: [DayScan] = await Task.detached(priority: .utility) {
            var out: [DayScan] = []
            for offset in 0..<maxDays {
                let dayStart = nowLocalMidnight - offset * 86_400
                let day = AnalyticsEngine.dayString(dayStart, offsetSec: tzOffset)
                // Read a generous window around the night that ends on `day`; the stager finds the span.
                let from = dayStart - 30 * 3_600
                // Sleep read-window END. For a PAST day the night may end any time before the NEXT local
                // midnight (late sleepers / weekend lie-ins / shift workers wake well after noon), so a
                // hard `dayStart + 18h` (6 PM) bound TRUNCATED the read at exactly 18:00 — and a real wake
                // past it was reported as a flat 18:00 wake (#500). Read a PAST day through to the next
                // local midnight so the stager sees the whole night; TODAY keeps the 18:00 cap (the store
                // clamps to `now` anyway, and an in-progress nap shouldn't be read as a finished night).
                let nextMidnight = dayStart + 86_400
                let to = (dayStart < nowLocalMidnight) ? nextMidnight : dayStart + 18 * 3_600

                // I2: pick the single device that owns this day, and read ITS streams below. With one device
                // this resolves to `deviceId` (active strap, has data → priority 0), so nothing changes; with
                // multiple sources the day is scored from exactly one (active strap > other live straps >
                // imports, or a locked override). Falls back to `deviceId` if the registry is unreadable.
                let owner = await Self.resolveDayOwner(day: day, from: from, to: to, store: store,
                                                       devices: regDevices, activeId: regActiveId,
                                                       registry: registry, fallbackDeviceId: ownerFallbackId)

                let hr = (try? await store.hrSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                guard hr.count >= 200 else { continue }   // need real raw data, not a stray sample
                let rr = (try? await store.rrIntervals(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                let resp = (try? await store.respSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                let grav = (try? await store.gravitySamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                let steps = (try? await store.stepSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                let skin = (try? await store.skinTempSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                // Wrist-wear events in the night window, paired into off-wrist [start, end) intervals for the
                // off-wrist sleep backstop (#500). The HR-gap proxy in the stager is the always-on guard;
                // these explicit intervals sharpen it under the FRACTIONAL rule (#504) — a session is dropped
                // only when its off-wrist coverage reaches maxOffWristSleepFraction, so a real night with a
                // short off-wrist tail survives. Pairing needs WRIST_ON too (to bound each interval); a span
                // still open at the window end closes at `to`. Empty when the strap emitted no wrist events.
                let wristEvents = (try? await store.events(deviceId: owner, from: from, to: to, limit: 50_000)) ?? []
                let wristOff = AnalyticsEngine.offWristIntervals(events: wristEvents, windowEnd: to)

                // Calendar-day window for the ADDITIVE daily totals (steps + calories). The night window
                // above is anchored to the current time-of-day and ends at dayStart+12h, so for a PAST
                // day whose late hours sit after that bound those hours are never read and the totals
                // undercount. Read exactly [localMidnight(day), localMidnight(day)+86400) and hand it to
                // analyzeDay's dayHr/daySteps, which use it ONLY for those totals. `dayStart` is already a
                // LOCAL midnight; midnightLocal is idempotent on it (the store range is inclusive, so end
                // at -1 s). (#277 — local-day bucketing.)
                let dayMid = Self.midnightLocal(dayStart, offsetSec: tzOffset)
                let dayEnd = dayMid + 86_400 - 1
                // Same `owner` as the night window above (I2): the additive day totals must come from the
                // one device that owns the day, never a mix.
                let dayHr = (try? await store.hrSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
                let daySteps = (try? await store.stepSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
                // Full calendar-day gravity for WORKOUT detection. The night window above ends at
                // dayStart+12h (≈ noon), so an afternoon/evening workout sits outside it and was only
                // detected once a later pass re-read it through the next night window — a ~day lag. This
                // [localMidnight, localMidnight+24h) read (today: clamped to `now` by the store) lets the
                // detector see the whole day, so a 5 pm run shows up on the same day.
                let dayGrav = (try? await store.gravitySamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []

                // CONSUME (#531 / H8): the prior pass's persisted v18 BAND sleep_state for sessions overlapping
                // the night window, expanded to timestamped (ts, state) samples on the 30 s grid, so the H7
                // morning-stillness guard can confirm a borderline re-onset against the strap's OWN scored band.
                // Read under `computedId` (where the prior pass banded its detected sessions); empty on the first
                // pass (no banded sessions yet) → the guard simply falls back to the HR bar. Honest: only real
                // banded "asleep" epochs rescue a block, never a fabricated one.
                let bandSleepState = await Self.bandSleepStateSamples(computedId: computedId,
                                                                      from: from, to: to, store: store)

                // #690: read the experimental-V2 toggle ONCE here (off the detached executor, matching the
                // Repository self-heal call site) and capture the Bool, so the Settings toggle now drives the
                // NORMAL detected-night staging path — not only the userEdited self-heal restage.
                let useSleepStagerV2 = PuffinExperiment.experimentalSleepV2Enabled

                // Already OFF the main actor — score directly (the prior nested `Task.detached` here only
                // existed to hop off the main actor; the whole loop now runs off it, so the score is computed
                // inline with the identical inputs and identical result).
                // Sleep & Rest test mode (E5): a per-day collector for the gate trace + Rest sub-score line,
                // built ONLY when the mode is active. nil otherwise = analyzeDay's byte-identical default path.
                var sleepTrace: [String] = []
                let traceSink: ((String) -> Void)? = sleepTraceActive ? { sleepTrace.append($0) } : nil
                let res = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: resp, gravity: grav,
                                                     steps: steps, dayHr: dayHr, daySteps: daySteps,
                                                     dayGravity: dayGrav,
                                                     skinTemp: skin,
                                                     profile: up, baselines: baselines1, maxHROverride: maxHR,
                                                     tzOffsetSeconds: tzOffset, wristOff: wristOff,
                                                     habitualMidsleepSec: habitualMidsleepSec,
                                                     bandSleepState: bandSleepState,
                                                     // #690: thread the V2 toggle into the NORMAL staging path so
                                                     // it affects detected nights, not just the self-heal restage.
                                                     useSleepStagerV2: useSleepStagerV2,
                                                     traceSink: traceSink)
                // ── Steps test mode: 5/MG raw-counter trace ──────────────────────────────────────────────
                // Only built when the Steps mode is on (the gate was read once before the loop). Recomputes
                // the SAME wrap-aware @57 sum analyzeDay just ran, over the SAME `daySteps` calendar-day
                // stream, so the reported scaledSteps equals the day's steps_est, so the trace cannot diverge.
                // Pure inputs, carried out so the main actor replays it tagged `.steps` in per-day order.
                var stepsTrace: [String] = []
                // #807: only a counter strap (WHOOP 5/MG) banks step samples — a WHOOP 4.0 has none, so without
                // this guard the trace spams "counterSamples=0 (need >=2 for a delta)" every day, reads as
                // broken, and buries the motion-volume calibration trace that actually explains a 4.0's steps.
                if stepsTraceActive && !daySteps.isEmpty {
                    stepsTrace = StepsEstimateEngine.rawCounterTrace(
                        daySteps: daySteps, dayKey: day, tzOffsetSeconds: tzOffset,
                        ticksPerStep: up.stepTicksPerStep)
                }
                // ── RHR floor-vs-mean diagnostic (#691) ────────────────────────────────────────────────
                // Make the recurring "NOOP's resting HR reads LOWER than my sleeping-HR app" reports
                // explainable from the strap log instead of a guess. The two numbers measure different
                // things BY DESIGN, not a bug: NOOP's `restingHr` is the WHOOP-style FLOOR (the lowest
                // sustained 5-min in-bed level — SleepStager picks the min 5-min rolling-mean HR per session,
                // and the day takes the .min() across them), whereas a "sleeping HR" app reports the night
                // MEAN over the whole asleep span. The mean always sits above the floor, so NOOP looking
                // lower is correct. Log BOTH so a report ships proof of the gap. Mean is computed over the
                // SAME matched in-bed span the floor came from (so they're directly comparable); a night
                // with no banked floor (no matched sleep) logs nil and the line is skipped. Logging only —
                // no scoring change. Counts/bpm only; no timestamps or PII (LiveState.append also scrubs).
                // Computed here (pure inputs) and carried out so the main actor can replay it through
                // `diagnosticSink` in the SAME per-day order — the sink is a MainActor-bound closure.
                var rhrLine: String?
                if let floor = res.daily.restingHr {
                    let inBedBpms = hr.filter { s in
                        res.cachedSleep.contains { s.ts >= $0.startTs && s.ts < $0.endTs }
                    }.map { $0.bpm }
                    rhrLine = Self.rhrFloorMeanLogLine(day: res.daily.day, floor: floor, inBedBpms: inBedBpms)
                }
                out.append(DayScan(result: res, rhrLine: rhrLine, sleepTrace: sleepTrace,
                                   stepsTrace: stepsTrace))
            }
            return out
        }.value

        // Back on the main actor: fold the off-actor results into the pass-2 state in the SAME order the
        // loop produced them. Pure assignment / appends — no further store reads — so this is cheap and the
        // main actor was free during the heavy enumeration above.
        for scan in scanned {
            let res = scan.result
            nightlyHrvByDay[res.daily.day] = res.daily.avgHrv
            nightlyRhrByDay[res.daily.day] = res.daily.restingHr.map(Double.init)
            nightlyRespByDay[res.daily.day] = res.daily.respRateBpm
            nightlySkinByDay[res.daily.day] = res.nightlySkinTempC
            if let line = scan.rhrLine { diagnosticSink?(line, nil) }
            // Sleep & Rest test mode (E5): replay this day's gate-trace + Rest lines tagged `.sleep` so they
            // land under the profile tag in the export. Empty unless the mode is active.
            for line in scan.sleepTrace { diagnosticSink?(line, .sleep) }
            // Steps test mode: replay this day's 5/MG raw-counter trace tagged `.steps`. Empty unless the
            // mode is active, so the default path emits zero `.steps` lines here.
            for line in scan.stepsTrace { diagnosticSink?(line, .steps) }
            scoredNights.append((daily: res.daily, strain: res.strain, cachedSleep: res.cachedSleep,
                                 workouts: res.workouts, nightlySkin: res.nightlySkinTempC,
                                 sessionMotion: res.sessionMotionByStart))
        }

        // ── Seed the baseline from the UNION of imported nightly history + the values just computed.
        // THIS is the BLE-only recovery fix: the "-noop" nightly avgHrv/restingHr finally feed the
        // baseline so a strap-only user crosses Baselines.minNightsSeed and recovery lights up.
        // IMPORTED values win per day: write them first, then fill ONLY days the import doesn't cover
        // (Swift has no putIfAbsent — `dict[day] == nil` is true only when the KEY is absent, so a day
        // imported with a nil avgHrv stays imported, not overwritten by the computed value).
        var histHrvByDay: [String: Double?] = [:]
        var histRhrByDay: [String: Double?] = [:]
        var histRespByDay: [String: Double?] = [:]
        for d in hist {
            histHrvByDay[d.day] = d.avgHrv
            histRhrByDay[d.day] = d.restingHr.map(Double.init)
            histRespByDay[d.day] = d.respRateBpm
        }
        for (day, v) in nightlyHrvByDay where histHrvByDay[day] == nil { histHrvByDay[day] = v }
        for (day, v) in nightlyRhrByDay where histRhrByDay[day] == nil { histRhrByDay[day] = v }
        for (day, v) in nightlyRespByDay where histRespByDay[day] == nil { histRespByDay[day] = v }
        // rhr/resp/skin honour the Charge-wide recalibration epoch (noop.recoveryBaselineEpoch); 0 = no-op,
        // so this is byte-identical to the plain fold until the user taps Recalibrate, at which point the
        // whole Charge build-up (HRV + resting HR + resp + skin) re-anchors together.
        let recoveryEpoch = Baselines.recoveryBaselineEpoch()
        let hrvDayKeys = histHrvByDay.keys.sorted()                         // chronological "yyyy-MM-dd"
        let hrvSeq = hrvDayKeys.map { histHrvByDay[$0]! }                   // chronological [Double?]
        let rhrDayKeys = histRhrByDay.keys.sorted()
        let rhrSeq = rhrDayKeys.map { histRhrByDay[$0]! }
        let respDayKeys = histRespByDay.keys.sorted()
        let respSeq = respDayKeys.map { histRespByDay[$0]! }
        // Skin-temp baseline is on-device-only (imported rows carry skinTempDevC, not the raw mean),
        // so fold purely over the pass-1 nightly means in chronological order.
        let skinDayKeys = nightlySkinByDay.keys.sorted()
        let skinSeq = skinDayKeys.map { nightlySkinByDay[$0]! }
        // Resp baseline gated on `usable`: RecoveryScorer includes the resp term whenever a
        // baseline object is present — a CALIBRATING (<4-night) baseline would let one noisy
        // RSA night move recovery (mirrors the skin-temp use-site gate; honest cold-start).
        let respFold = Baselines.foldHistory(respSeq, dayKeys: respDayKeys, cfg: respCfg, baselineEpoch: recoveryEpoch)
        // Skin-temp gated the same way for consistency: its only use-site re-checks `.usable`
        // (AnalyticsEngine's skinTempDevC guard) so this is belt-and-suspenders, but it stops a
        // future use-site from trusting a CALIBRATING baseline. (PR #97 review.)
        let skinFold = Baselines.foldHistory(skinSeq, dayKeys: skinDayKeys, cfg: skinCfg, baselineEpoch: recoveryEpoch)
        let baselines2 = AnalyticsEngine.ProfileBaselines(
            // HRV honours noop.hrvBaselineEpoch; rhr/resp/skin honour noop.recoveryBaselineEpoch via their
            // parallel day keys, so the manual Recalibrate restarts the whole Charge build-up together.
            hrv: Baselines.foldHistory(hrvSeq, dayKeys: hrvDayKeys, cfg: hrvCfg),
            restingHR: Baselines.foldHistory(rhrSeq, dayKeys: rhrDayKeys, cfg: rhrCfg, baselineEpoch: recoveryEpoch),
            resp: respFold.usable ? respFold : nil,
            skinTemp: skinFold.usable ? skinFold : nil)

        // Real (non-detected) workouts in the scored window, used to de-duplicate detected bouts so a
        // user who BOTH has real sessions AND wears the strap doesn't see the same session twice (the
        // per-day merge precedence does not cover the workout table). This covers BOTH directions of
        // the cross-source duplicate (#107): the strap source carries imported WHOOP rows AND manual /
        // re-labelled rows (both written under `deviceId`), and apple-health carries Health imports —
        // a detected bout overlapping ANY of them is skipped below. Port of the Android dedup block.
        // (`computedId` is bound once above, before the off-actor scan loop.)
        let windowStart = now - maxDays * 86_400 - 30 * 3_600
        var realWorkouts = (try? await store.workouts(deviceId: deviceId, from: windowStart,
                                                       to: now, limit: 100_000)) ?? []
        realWorkouts += (try? await store.workouts(deviceId: "apple-health", from: windowStart,
                                                    to: now, limit: 100_000)) ?? []

        // ── Pass 2: re-score ONLY recovery against the now-seeded baseline (cheap, baseline-dependent);
        // every other field was computed once in pass 1. Recovery stays nil until the HRV baseline is
        // usable (≥ minNightsSeed valid nights) — honest cold-start, via RecoveryScorer's usable gate.
        var out: [Computed] = []
        var dailies: [DailyMetric] = []
        var cachedSleep: [CachedSleepSession] = []
        var workoutRows: [WorkoutRow] = []
        // Rest composite (0–100) per computed night, persisted as the `sleep_performance` metric
        // series so the dashboard's Rest score reflects the new composite, not raw efficiency.
        var restPoints: [MetricPoint] = []
        // User-corrected sleep windows override the detected sleep when scoring a day's sleep aggregates,
        // so Rest + recovery honor the edit — not just the Sleep tab's session view. An edited block
        // substitutes its detected twin (matched by the stable detected startTs) before totals recompute.
        // Scope (#318): this only covers the COMPUTED ("-noop") source — the days noop scores itself. An
        // edit to an IMPORTED (WHOOP-export) night updates the displayed session, but its dashboard
        // recovery/performance come verbatim from the export and are NOT recomputed here (we don't
        // reproduce WHOOP's cloud scoring). That's an accepted limitation, documented on the PR.
        // Self-heal any night edited before its raw streams synced (see `Repository.selfHealEditedStages`):
        // re-derive stages from the now-available raw over the night's locked bounds, then return the
        // refreshed rows so the daily aggregate below scores the corrected breakdown. A no-op for nights
        // already staged from raw (idempotent) and for imported nights (raw never dense). This MUST run
        // before the scoring loop so the healed stages flow into Rest/recovery this same pass.
        let editedRows = await repo.selfHealEditedStages(from: windowStart, to: now)
        let editsByStart = Dictionary(editedRows.map { ($0.startTs, $0) }, uniquingKeysWith: { a, _ in a })

        // Provenance sets for the honest By-Day badge + the per-day diagnostic source token. `hist` is the
        // imported daily rows under `deviceId` (the WHOLE imported history, read above for the baseline) —
        // a non-nil row means a WHOOP export covers that day and WINS the dashboard merge over our computed
        // row (Repository.mergeDaily: imports win field-by-field). Apple-Health daily rows are the same for
        // the Apple brand. Both are key-presence sets only (no values leave), so the lookup is O(1) per day
        // and nothing about the imported numbers is exposed. WHOOP wins over Apple, matching the merge's
        // source priority (whoopImport 0 < appleHealth 2 in DailyMetricSource.vitalPriority).
        let importedWhoopDays = Set(hist.map { $0.day })
        // The WHOLE apple-health daily history, chronological. Used both as a key-presence set for the
        // By-Day badge AND as the SDNN+RHR input for the Apple-Watch recovery fold below (a watch-only user
        // has these daily aggregates but no raw stream, so the raw-HR scoring loop never touched them).
        let appleRows = ((try? await store.dailyMetrics(deviceId: Repository.appleHealthSource,
                                                        from: "0000-01-01", to: "9999-12-31")) ?? [])
            .sorted { $0.day < $1.day }
        let appleHealthDays = Set(appleRows.map { $0.day })

        // Recovery (Charge) test mode (Group G): read the zero-cost gate ONCE here (a single Bool) before
        // the scoring loop. When false (the default), no Charge term-breakdown trace is built and the score
        // path is byte-identical. When true, each scored night emits its Charge breakdown tagged `.recovery`
        // via `recoveryTrace`, which returns the SAME score `recomputeRecovery` computes (it reuses
        // RecoveryScorer.recovery verbatim), so the headline Charge number is unaffected.
        let recoveryTraceActive = TestCentre.active(.recovery)
        for night in scoredNights {
            let daily = sleepEditedDaily(night.daily, detected: night.cachedSleep, editsByStart: editsByStart,
                                         habitualMidsleepSec: habitualMidsleepSec)
            let recovery = recomputeRecovery(daily, baselines2)
            // Charge term-breakdown trace (Group G): only when the Recovery test mode is on. Emits which
            // term moved Charge and which was nil and forced the renorm, tagged `.recovery`. The trace's
            // score is RecoveryScorer.recovery verbatim, so the `recovery` written above is unchanged.
            if recoveryTraceActive {
                for line in recoveryTraceLines(daily, baselines2) { diagnosticSink?(line, .recovery) }
            }
            let skinDev = recomputeSkinTempDev(night.nightlySkin, baselines2.skinTemp)
            let source = DaySource.classify(day: daily.day, importedWhoopDays: importedWhoopDays,
                                            appleHealthDays: appleHealthDays)
            out.append(Computed(day: daily.day, recovery: recovery, strain: night.strain,
                                sleepMin: daily.totalSleepMin, hrv: daily.avgHrv,
                                rhr: daily.restingHr, source: source))
            // ── Per-day scoring diagnostic (Sleep overhaul §2.5) ─────────────────────────────────────
            // ONE concise, privacy-safe line per scored day into the shareable strap log: the day key, the
            // FINAL computed total-sleep minutes (after any edit substitution), how many sleep blocks the
            // detector matched on the day, and the provenance of the dashboard headline. Counts + a rounded
            // minute only — no HR/HRV/timestamps — so the next report ships PROOF of what was computed per
            // day (the project's log-failures-not-successes blind spot) and lets us settle the "Rest repeats
            // across days" question with data rather than a guess. Gated by the existing strap-log export.
            let tsmLog = daily.totalSleepMin.map { String(Int($0.rounded())) } ?? "nil"
            diagnosticSink?("sleep day=\(daily.day) totalSleepMin=\(tsmLog) "
                            + "matched=\(night.cachedSleep.count) source=\(source.logToken)", nil)
            dailies.append(daily.with(recovery: recovery, skinTempDevC: skinDev))
            if let rest = AnalyticsEngine.Rest.composite(daily: daily) {
                restPoints.append(MetricPoint(day: daily.day, key: "sleep_performance", value: rest))
            }
            cachedSleep.append(contentsOf: night.cachedSleep)
            // Persist the detected workouts the pipeline already computes (previously discarded).
            // Skip any bout overlapping a real imported workout so import+wear users don't
            // double-count. sport = "detected"; energyKcal is the APPROXIMATE Keytel/BMR total.
            for s in night.workouts {
                if realWorkouts.contains(where: { s.start < $0.endTs && $0.startTs < s.end }) { continue }
                workoutRows.append(WorkoutRow(startTs: s.start, endTs: s.end,
                                              sport: "detected", source: computedId,
                                              durationS: s.durationS, energyKcal: s.caloriesKcal,
                                              avgHr: Int(s.avgHR), maxHr: s.peakHR,
                                              strain: s.strain, distanceM: nil,
                                              zonesJSON: nil, notes: nil))
            }
        }

        // ── Apple-Watch recovery fold (M1 "Watch as a device") ──────────────────────────────────────
        // A watch-only user has apple-health DAILY aggregates (SDNN HRV + resting HR) but no raw stream, so
        // the raw-HR scoring loop above never touched their days and the import left `recovery: nil`. Fill
        // that one gap from the daily aggregate vs the person's own baseline (the cross-lane `WatchRecovery`
        // engine, which mirrors our Charge recovery shape). WHOOP/computed recovery MUST keep winning where
        // both exist, so we skip any day a strap already OWNS: every day the raw-HR loop scored (in `out`,
        // even a cold-start nil-recovery night — that day belongs to the strap, not the watch) plus every
        // WHOOP-imported day (the export carries its own recovery). The result is written back onto the
        // apple-health rows so the source-aware dashboard reads it, and the watch-only days are appended to
        // `out` so the By-Day list shows them with their honest confidence.
        let strapRecoveryDays = Set(out.map { $0.day }).union(importedWhoopDays)
        let watchScored = Self.watchRecoveries(appleRows: appleRows, strapRecoveryDays: strapRecoveryDays)
        // Persist the recovery onto each apple-health row that gained one (nil-recovery days are left as-is,
        // never fabricated). Rebuild the row with the new recovery; every other field is unchanged.
        var appleRecoveryRows: [DailyMetric] = []
        let appleByDay = Dictionary(appleRows.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for w in watchScored {
            guard let recovery = w.recovery, let row = appleByDay[w.day] else { continue }
            appleRecoveryRows.append(row.with(recovery: recovery, skinTempDevC: row.skinTempDevC))
            // Surface the watch-only day in the By-Day list with its watch provenance + confidence.
            out.append(Computed(day: w.day, recovery: recovery, strain: row.strain,
                                sleepMin: row.totalSleepMin, hrv: row.avgHrv, rhr: row.restingHr,
                                source: .appleHealth, confidence: w.confidence))
        }
        if !appleRecoveryRows.isEmpty {
            _ = try? await store.upsertDailyMetrics(appleRecoveryRows, deviceId: Repository.appleHealthSource)
        }

        // #277 migration: the loop now keys days by the LOCAL calendar day. A prior run (before this
        // fix) wrote the SAME period under UTC-day keys, so without a cleanup an off-by-one UTC row and
        // the new local row would coexist as duplicate days. We reconcile the COMPUTED ("-noop") daily
        // rows across the recompute window [oldest enumerated local day, newest]: UPSERT the freshly
        // local-keyed rows FIRST, then delete only the STALE rows the new run no longer produces.
        //
        // #521: the old order was delete-the-whole-window THEN re-upsert — a non-atomic gap where a
        // concurrent refresh could read `repo.days.count` LOWER (post-delete) then HIGHER (post-upsert),
        // which the Today inbox mistook for new history and announced as "New data added" on a loop. By
        // upserting before deleting, the row count is MONOTONIC (it only grows or holds during a
        // recompute), so recompute churn can never masquerade as growth. Scoped to the computed source
        // only — imported "my-whoop" rows are never touched (a BLE-only WHOOP 4.0 user has no import
        // fallback). Rows older than the window keep their old keys (cosmetic off-by-one, acceptable).
        // yyyy-MM-dd sorts chronologically, so the string range IS a date range.
        let oldestDay = AnalyticsEngine.dayString(nowLocalMidnight - (maxDays - 1) * 86_400,
                                                  offsetSec: tzOffset)
        let newestDay = AnalyticsEngine.dayString(nowLocalMidnight, offsetSec: tzOffset)

        // Persist the computed scores under a dedicated "-noop" source so the WHOLE dashboard
        // (Today / Recovery / Strain / Sleep / Trends), not just this screen, reads them. The
        // Repository merges these UNDER any imported "my-whoop" rows, so a real WHOOP import
        // always wins; this only fills the days the strap collected but no import covered.
        // Upsert FIRST so the row count never transiently dips (#521).
        if !dailies.isEmpty { _ = try? await store.upsertDailyMetrics(dailies, deviceId: computedId) }

        // Now evict only the STALE computed rows in the window — those a prior (e.g. UTC-keyed) run left
        // behind that the current local-keyed run no longer produces. Read the window, diff against the
        // keys we just upserted, and delete each leftover day individually (from == to == key). This
        // removes #277's UTC/local duplicates WITHOUT the wide delete-then-reinsert dip. No-op in steady
        // state (the new keys cover the window), so it adds nothing once the migration has settled.
        let freshKeys = Set(dailies.map { $0.day })
        let existingWindow = (try? await store.dailyMetrics(deviceId: computedId, from: oldestDay, to: newestDay)) ?? []
        for stale in existingWindow where !freshKeys.contains(stale.day) {
            _ = try? await store.deleteDailyMetrics(deviceId: computedId, from: stale.day, to: stale.day)
        }
        if !restPoints.isEmpty { _ = try? await store.upsertMetricSeries(restPoints, deviceId: computedId) }

        // ── Fitness Age (Phase 2) — weekly, keyed to the week's Saturday ────────────────────────────
        // Roll the last 7 computed days into the Nes/HUNT inputs and upsert a weekly Fitness Age (+ an
        // optional VO₂max when a waist is set) under the same "-noop" source. Idempotent on the Saturday
        // key, so the number refines through the week and finalises on Saturday. Engine = FitnessAgeEngine
        // (StrandAnalytics), fully unit-tested; the body term cancels so the headline needs no body metric.
        let fa7 = dailies.sorted { $0.day < $1.day }.suffix(7)
        let faRHRs = fa7.compactMap { $0.restingHr }.map(Double.init)
        let faActiveStrains = fa7.compactMap { $0.strain }.filter { $0 >= 30 }
        let faMeanActiveStrain = faActiveStrains.isEmpty ? 0
            : faActiveStrains.reduce(0, +) / Double(faActiveStrains.count)
        let faWaist: Double? = profile.waistCm > 0 ? profile.waistCm : nil
        let faReady = FitnessAgeEngine.assessReadiness(
            hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty,
            rhrDays: faRHRs.count, activityDays: fa7.compactMap { $0.strain }.count,
            hasHeightWeight: profile.heightCm > 0 && profile.weightKg > 0, hasWaist: faWaist != nil)
        if faReady.canCompute,
           let faRes = FitnessAgeEngine.compute(
                age: Double(profile.age), sex: profile.sex,
                restingHR: IntelligenceEngine.medianOf(faRHRs),
                paIndex: FitnessAgeEngine.physicalActivityIndexFromStrain(
                    activeDaysPerWeek: faActiveStrains.count, meanActiveStrain: faMeanActiveStrain),
                waistCm: faWaist) {
            let satKey = IntelligenceEngine.saturdayKey(onOrBefore: newestDay)
            var faPts = [MetricPoint(day: satKey, key: "fitness_age", value: faRes.fitnessAge)]
            if let v = faRes.vo2max { faPts.append(MetricPoint(day: satKey, key: "vo2max_est", value: v)) }
            _ = try? await store.upsertMetricSeries(faPts, deviceId: computedId)
        }

        // ── Vitality / Body Age (Phase 7) — weekly, keyed to the week's Saturday ────────────────────
        // Roll the last 7 days' wearable signals into the mortality-hazard model and upsert a weekly
        // Vitality (0–100) + Body Age. VitalityEngine gates on ≥3 inputs, so a sparse week writes nothing.
        // (VO₂max is omitted here — fitness is already its own Fitness Age headline; Vitality leans on
        // resting HR, sleep duration + regularity, HRV-vs-age-norm, and steps.)
        let vNights = fa7.compactMap { $0.totalSleepMin }.map { Double($0) / 60.0 }.filter { $0 > 0 }
        let vHRVs = fa7.compactMap { $0.avgHrv }
        let vSteps = fa7.compactMap { $0.steps }.map(Double.init)
        let vInputs = VitalityEngine.Inputs(
            chronoAge: Double(profile.age),
            restingHR: faRHRs.isEmpty ? nil : IntelligenceEngine.medianOf(faRHRs),
            sleepHours: vNights.isEmpty ? nil : vNights.reduce(0, +) / Double(vNights.count),
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: vNights),
            rmssd: vHRVs.isEmpty ? nil : IntelligenceEngine.medianOf(vHRVs),
            rmssdNorm: VitalityEngine.rmssdNorm(forAge: Double(profile.age)),
            steps: vSteps.isEmpty ? nil : vSteps.reduce(0, +) / Double(vSteps.count))
        if let vRes = VitalityEngine.compute(vInputs) {
            let satKey = IntelligenceEngine.saturdayKey(onOrBefore: newestDay)
            _ = try? await store.upsertMetricSeries([
                MetricPoint(day: satKey, key: "vitality", value: vRes.vitality),
                MetricPoint(day: satKey, key: "body_age", value: vRes.bodyAge),
            ], deviceId: computedId)
        }

        // ── Steps ESTIMATE (WHOOP 4.0) — DAILY, keyed to each strap-only day ────────────────────────
        // A WHOOP 4.0 sends no step count over BLE, so for days the phone DIDN'T also count steps we
        // estimate them: calibrate the strap's daily MOTION VOLUME against the phone's real step count
        // on the days both exist, then apply that personal coefficient to the strap-only days. Engine =
        // StepsEstimateEngine (StrandAnalytics), fully unit-tested; this block is pure orchestration —
        // gather points, fit, store under the same "-noop" source, mirror to ProfileStore for the UI.
        //
        // Idempotent: re-upserts the same (computedId, day, "steps_est") rows. Inert until there's a
        // calibration — a single-source / no-phone user sees no estimate until they set a manual `k`.
        //
        // Calibration window: a generous 60 days (not just the 7 the weekly engines use) so enough
        // both-have days accumulate to fit. Reference steps = the apple-health daily `steps` value
        // (the same source the dashboard's `steps` metric reads, Repository.swift). Motion = the
        // [localMidnight, +24h) gravity volume, the same calendar-day window the daily totals use.
        let stepsCalDays = 60
        let calOldest = AnalyticsEngine.dayString(
            nowLocalMidnight - (stepsCalDays - 1) * 86_400, offsetSec: tzOffset)
        // ── FIX 2 (main-actor jank): hoist the 60-day steps-calibration STORE READS off the main actor ──
        // Same residual stall FIX 1 fixed, smaller scale: this class is `@MainActor`, so each `await store.…`
        // below resumes its continuation ON the main actor — the apple-health read + 60 per-day
        // owner-resolve/gravity reads add 60+ read-resumes of main-actor contention every analyzeRecent.
        // The reads touch NO `@Published`/`profile`/`registry`-isolated state — only the captured immutable
        // inputs (calOldest/newestDay/nowLocalMidnight/tzOffset/regDevices/regActiveId), the `WhoopStore`
        // actor, the nonisolated `registry`, the nonisolated-static `resolveDayOwner`, and the pure static
        // `StepsEstimateEngine.dayMotionIntensity`. So we hoist the whole gather into ONE
        // `Task.detached(priority:.utility)` whose continuations resume OFF the main actor, returning two
        // plain `[String: Double]` value types (fully Sendable — even cleaner than FIX 1's [DayScan]). The
        // pure `StepsEstimateEngine.calibrate/estimate/status` fit + the `profile.*` assignments stay on the
        // main actor below, consuming those dictionaries. Same per-day inputs (same window, same owner
        // resolution, same `m > 0` / `steps > 0` filters), same outputs — only the executor the reads resume
        // on changes. Bind `deviceId` (a MainActor instance `let`) to a local Sendable `String` so the
        // @Sendable detached closure captures the VALUE, never `self`, exactly as FIX 1's `ownerFallbackId`.
        let stepsFallbackId = deviceId
        let (refStepsByDay, motionByDay): ([String: Double], [String: Double]) =
            await Task.detached(priority: .utility) {
            // Phone reference steps per day, from the apple-health daily rows (steps > 0 only).
            // #693: read `appleDaily`, NOT `dailyMetrics`. Apple-Health import writes the phone step count into
            // `appleDaily.steps` (Int?), never into a dailyMetric `steps` row — so the old `dailyMetrics` read
            // was always empty and the calibration never advanced past "Need 3 more days" (Android already reads
            // appleDaily here, IntelligenceEngine.kt:676). `store.appleDaily(deviceId:from:to:)` already exists.
            let appleRows = (try? await store.appleDaily(deviceId: Repository.appleHealthSource,
                                                         from: calOldest, to: newestDay)) ?? []
            var refSteps: [String: Double] = [:]
            for r in appleRows { if let s = r.steps, s > 0 { refSteps[r.day] = Double(s) } }
            // Per-day motion volume over the calibration window, read from the owner-resolved strap streams.
            // (Owner resolution mirrors the scoring loop; one device installs resolve to `deviceId`.)
            var motion: [String: Double] = [:]
            for off in 0..<stepsCalDays {
                let dayMid = Self.midnightLocal(nowLocalMidnight - off * 86_400, offsetSec: tzOffset)
                let dayEnd = dayMid + 86_400 - 1
                let dayKey = AnalyticsEngine.dayString(dayMid, offsetSec: tzOffset)
                let owner = await Self.resolveDayOwner(day: dayKey, from: dayMid, to: dayEnd, store: store,
                                                       devices: regDevices, activeId: regActiveId,
                                                       registry: registry, fallbackDeviceId: stepsFallbackId)
                let grav = (try? await store.gravitySamples(deviceId: owner, from: dayMid, to: dayEnd,
                                                            limit: 200_000)) ?? []
                let m = StepsEstimateEngine.dayMotionIntensity(grav)
                if m > 0 { motion[dayKey] = m }
            }
            return (refSteps, motion)
        }.value
        // Build calibration points only for days with BOTH a motion volume and a real phone step count.
        let calPoints = motionByDay.compactMap { (day, motion) -> StepsEstimateEngine.CalibrationPoint? in
            guard let s = refStepsByDay[day] else { return nil }
            return StepsEstimateEngine.CalibrationPoint(motion: motion, steps: s)
        }
        if let cal = StepsEstimateEngine.calibrate(calPoints, manualOverride: profile.stepsManualOverride) {
            // Estimate + upsert for each recent scored day that has motion but NO real phone step count.
            // (Days the phone DID count keep their real value — surfaced directly by the Today tile, not
            // overwritten by an estimate.) This runs AFTER any timestamp-heal upstream, so the motion it
            // reads is the healed-day motion, never pre-heal.
            var estPts: [MetricPoint] = []
            for dm in dailies where refStepsByDay[dm.day] == nil {
                guard let motion = motionByDay[dm.day],
                      let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
                estPts.append(MetricPoint(day: dm.day, key: "steps_est", value: Double(est)))
            }
            if !estPts.isEmpty { _ = try? await store.upsertMetricSeries(estPts, deviceId: computedId) }
            // Mirror the fit into ProfileStore so the Settings/Steps screen can show + adjust it.
            profile.stepsCalibrationCoefficient = cal.coefficient
            profile.stepsCalibrationSampleDays = cal.sampleDays
            profile.stepsCalibrationConfidence = cal.confidence
            profile.stepsCalibrationManual = cal.manual
        } else {
            // Not yet calibrated (too few overlapping phone-counted days, no manual override). Classify the
            // STATE (#589) and persist the PROGRESS so the Today tile/Settings can say how many more days are
            // needed rather than going silently blank. `status` uses the SAME usable-day filter the fit does.
            // Coefficient stays 0 (the "not calibrated" gate the UI already keys off); sampleDays carries the
            // usable-day count so the message can compute "need N more".
            let stepsStatus = StepsEstimateEngine.status(calPoints, manualOverride: profile.stepsManualOverride)
            if case let .needsMoreDays(have, _) = stepsStatus {
                profile.stepsCalibrationCoefficient = 0
                profile.stepsCalibrationSampleDays = have
                profile.stepsCalibrationConfidence = 0
                profile.stepsCalibrationManual = false
            }
        }

        // Steps test mode: emit the WHOOP-4 motion-volume calibration trace (per-day points + the fitted /
        // manual / withheld calibration state) and a per-day estimate line, tagged `.steps`. Only when the
        // mode is on (the gate was read once before the scan loop), so the default path emits zero `.steps`
        // lines here. The trace reuses StepsEstimateEngine.calibrate/estimate VERBATIM, so it cannot diverge
        // from the coefficient + steps_est just written above.
        if stepsTraceActive {
            for line in StepsEstimateEngine.calibrationTrace(points: calPoints,
                                                             manualOverride: profile.stepsManualOverride) {
                diagnosticSink?(line, .steps)
            }
            if let cal = StepsEstimateEngine.calibrate(calPoints, manualOverride: profile.stepsManualOverride) {
                for dm in dailies where refStepsByDay[dm.day] == nil {
                    guard let motion = motionByDay[dm.day],
                          let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
                    diagnosticSink?("stepsEst day=\(dm.day) steps=\(est) "
                        + "motion=\((motion * 100).rounded() / 100) (motion-volume estimate)", .steps)
                }
            }
        }

        // Drop any freshly-detected session that overlaps a night the user has already hand-corrected.
        // A detected onset can drift second-to-second as more raw data arrives, so without this the
        // re-detected night would upsert as a SECOND row beside the edited one (different startTs ⇒ no
        // ON CONFLICT match), and mergeDay would DOUBLE-COUNT both into an inflated time-in-bed. The
        // edited row is already stored (preserved by the upsert guard), so we simply don't re-insert its
        // detected twin. Sleep has no delete-reinsert pass (unlike dailyMetric/workout), so this is the
        // idempotency guard for the edited case. (#318)
        let editedWindows = editedRows.map { (start: $0.effectiveStartTs, end: $0.endTs) }
        // #68: also drop any re-detected night the user has DELETED — a dismissedSleep tombstone keeps it
        // from regenerating, mirroring the dismissed-WORKOUT guard above. Overlap (not exact startTs)
        // because a re-detected onset drifts as more raw data arrives. (Android twin: dismissedWindows.)
        let dismissedWindows = repo.dismissedSleepWindows()
        let skipWindows = editedWindows + dismissedWindows
        let cachedSleepKept = cachedSleep.filter { s in
            !skipWindows.contains { s.startTs < $0.end && $0.start < s.endTs }   // time-overlap test
        }
        if !cachedSleepKept.isEmpty { _ = try? await store.upsertSleepSessions(cachedSleepKept, deviceId: computedId) }
        // ── Persist per-epoch motion (H8) beside each kept session's stagesJSON ──────────────────────────
        // The sleepSession rows exist now (just upserted), so the targeted motion UPDATE lands. Persist ONLY
        // for the sessions actually kept (not edited/dismissed), keyed by the detected start `analyzeDay`
        // returned. A session whose gravity wouldn't grid was omitted from the map and is left as NULL — an
        // absent motion series stays absent, never a fabricated zero array.
        let keptStarts = Set(cachedSleepKept.map { $0.startTs })
        var motionByStart: [Int: [Double]] = [:]
        for night in scoredNights {
            for (start, motion) in night.sessionMotion where keptStarts.contains(start) {
                motionByStart[start] = motion
            }
        }
        for (start, motion) in motionByStart {
            _ = try? await store.persistSessionMotion(deviceId: computedId, sessionStart: start, motionEpochs: motion)
        }
        // Make re-detection idempotent across runs: clear the prior computed detected workouts in the
        // scored window (a bout's startTs can drift as more HR arrives, which would otherwise orphan
        // stale rows under the (deviceId,startTs,sport) key), then re-insert.
        _ = try? await store.deleteWorkouts(deviceId: computedId, sport: "detected",
                                            from: windowStart, to: now)
        if !workoutRows.isEmpty { _ = try? await store.upsertWorkouts(workoutRows, deviceId: computedId) }

        // #137: a manually-started workout is scored from sparse live HR at save time — near-zero
        // calories/strain on a 5/MG. Now that offloaded HR may cover the window, re-score the
        // under-sampled ones from that denser data.
        await rescoreManualWorkouts(store: store, profile: up)

        results = out
        note = out.isEmpty
            ? "No scored nights yet. Wear the strap with NOOP connected overnight and the engine will score your charge, effort and rest itself, no WHOOP cloud required."
            : nil

        // Reload the dashboard caches so the freshly computed scores show up immediately.
        if !dailies.isEmpty { await repo.refresh() }
    }

    /// Resolve the SINGLE device that owns `day` (invariant I2), so the day is scored from exactly one
    /// source — never a mix. Builds one `DayOwnerResolver.Candidate` per non-archived device with a
    /// priority (0 = the active strap, 1 = other live straps, 2 = imports; lower wins) and a CHEAP
    /// per-day presence flag (one `LIMIT 1` HR read per device), then applies any locked override from
    /// the dayOwnership table. Returns `deviceId` when the registry yields no owner (no candidate has
    /// data, or it's empty/unreadable) so the legacy single-source path is preserved.
    ///
    /// Single-device install: the only paired row is the seeded active 'my-whoop' (== `fallbackDeviceId`).
    /// Its candidate is priority 0 with `hasData == true` for any day the strap collected HR, so the
    /// resolver returns `fallbackDeviceId` and the caller's reads are byte-identical to the pre-I2 code.
    /// The presence check is the same `LIMIT 1` over the same window the caller already reads.
    ///
    /// `nonisolated static` (FIX 1): the body touches NO `@Published`/instance-isolated state — only the
    /// passed-in `store` actor, the nonisolated `registry` struct, the value params, and `fallbackDeviceId`
    /// (the former `self.deviceId`). Making it `nonisolated` lets the off-main scan loop call it WITHOUT
    /// hopping back to the main actor each iteration, which is the whole point of FIX 1. Logic identical.
    nonisolated static func resolveDayOwner(day: String, from: Int, to: Int, store: WhoopStore,
                                            devices: [PairedDevice], activeId: String,
                                            registry: DeviceRegistryStore,
                                            fallbackDeviceId: String) async -> String {
        // A locked override wins outright and skips the presence checks entirely.
        if let locked = (try? registry.dayOwner(day))?.deviceId {
            return locked
        }
        // No registry rows (shouldn't happen — v15 seeds one — but be safe): keep the legacy id.
        guard !devices.isEmpty else { return fallbackDeviceId }

        var candidates: [DayOwnerResolver.Candidate] = []
        for d in devices where d.status != .archived {
            let isImport = d.sourceKind == .cloudImport || d.sourceKind == .fileImport
            let priority = d.id == activeId ? 0 : (isImport ? 2 : 1)
            // Cheap presence check: a single HR row for this device in the night window is enough to
            // mark it a candidate. (LIMIT 1 — not the full pull the caller does once an owner is chosen.)
            let hasData = !((try? await store.hrSamples(deviceId: d.id, from: from, to: to, limit: 1)) ?? []).isEmpty
            candidates.append(DayOwnerResolver.Candidate(deviceId: d.id, priority: priority, hasData: hasData))
        }
        return DayOwnerResolver.resolve(day: day, lockedOwner: nil, candidates: candidates) ?? fallbackDeviceId
    }

    /// #137: re-score under-sampled manual workouts. A `manual` workout is scored from the live HR
    /// captured during the session; on a 5/MG that stream is sparse, so calories/strain land near zero.
    /// The strap banks its own HR and offloads it on sync — once that denser HR covers the workout's
    /// window, recompute from it. Conservative + idempotent: only `manual` rows that look under-scored
    /// (negligible calories), and only when the recompute is a genuine improvement — so a well-scored
    /// 4.0 workout is never touched and a still-sparse window is a no-op.
    private func rescoreManualWorkouts(store: WhoopStore, profile up: UserProfile) async {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - 14 * 86_400
        guard let rows = try? await store.workouts(deviceId: deviceId, from: since, to: now, limit: 200)
        else { return }
        let hrMax = Double(profile.hrMax)
        var updated: [WorkoutRow] = []
        for row in rows where row.source == "manual"
            && ManualWorkoutRescore.looksUnderScored(currentKcal: row.energyKcal) {
            guard let samples = try? await store.hrSamples(deviceId: deviceId, from: row.startTs,
                                                           to: row.endTs, limit: 20_000),
                  let s = ManualWorkoutRescore.scored(windowSamples: samples, profile: up, hrMax: hrMax),
                  ManualWorkoutRescore.improves(s, over: row.energyKcal)
            else { continue }
            updated.append(WorkoutRow(
                startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
                durationS: row.durationS, energyKcal: s.kcal, avgHr: s.avgHr, maxHr: s.maxHr,
                strain: s.strain, distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes))
        }
        if !updated.isEmpty { _ = try? await store.upsertWorkouts(updated, deviceId: deviceId) }
    }

    /// Re-score ONLY the recovery composite for a day against a (re-seeded) baseline. Every other field
    /// in `daily` is baseline-independent and already final from pass 1. Returns nil until the HRV
    /// baseline is usable (RecoveryScorer gates on `hrvBaseline.usable`, i.e. ≥ minNightsSeed valid
    /// nights) — so the honest null-until-4-nights cold-start is free. Mirrors AnalyticsEngine's own
    /// recovery call + Android IntelligenceEngine.recomputeRecovery. (#78)
    private func recomputeRecovery(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines) -> Double? {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else { return nil }
        // Charge enrichment: feed the Rest COMPOSITE (÷100) as the sleep-quality term instead of raw
        // efficiency, and fold in the night's skin-temp deviation. Both come from the persisted daily
        // fields (the raw streams are gone in pass 2). (Charge/Effort/Rest scoring redesign.)
        let restQuality = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency
        return RecoveryScorer.recovery(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                       hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                       respBaseline: baselines.resp, sleepPerf: restQuality,
                                       skinTempDev: daily.skinTempDevC)
    }

    /// The Charge term-breakdown trace lines for one day (Recovery test mode, Group G). Pure: it feeds the
    /// SAME inputs `recomputeRecovery` does (the SAME `restQuality` derivation) into RecoveryScorer's
    /// side-effect-free `recoveryTrace`, whose returned score IS `RecoveryScorer.recovery` verbatim, so the
    /// trace can never diverge from the Charge number written for the day. Empty when a hard input
    /// (HRV / RHR / HRV-baseline) is missing, mirroring `recomputeRecovery`'s own early-nil. Only CALLED
    /// when `TestCentre.active(.recovery)` is true, so it costs nothing when the mode is off.
    private func recoveryTraceLines(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines) -> [String] {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else {
            return ["charge day=\(daily.day) nilScore reason=missingInput "
                + "(hrv/rhr/hrvBaseline required)"]
        }
        let restQuality = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency
        let (_, trace) = RecoveryScorer.recoveryTrace(
            hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
            hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
            respBaseline: baselines.resp, sleepPerf: restQuality,
            skinTempDev: daily.skinTempDevC)
        // Prefix each line with the day key so a multi-night export stays parseable, matching the sleep
        // trace's per-day shape. Strip ONLY the leading "charge " token the trace builder writes (every
        // line starts with it), then re-emit as "charge day=<day> ...".
        return trace.map { line in
            let body = line.hasPrefix("charge ") ? String(line.dropFirst("charge ".count)) : line
            return "charge day=\(daily.day) " + body
        }
    }

    /// One day's watch-derived recovery output, keyed by day.
    struct WatchScoredDay: Equatable {
        let day: String
        let recovery: Double?
        let confidence: ScoreConfidence
    }

    /// Compute Apple-Watch recovery (Charge) for the apple-health days that lack a strap recovery.
    ///
    /// The Apple Watch gives DAILY aggregates (an SDNN HRV reading + a resting HR), not a WHOOP-density raw
    /// stream, so the normal `analyzeRecent` raw-HR path (`hr.count >= 200`) never scores these days and the
    /// import leaves `recovery: nil`. This fills that one gap: for each apple-health day it folds the TRAILING
    /// SDNN + RHR history (every earlier apple-health day's `avgHrv` / `restingHr`) into the cross-lane
    /// `WatchRecovery` engine, which mirrors our Charge recovery shape but reads Apple's daily values. It stays
    /// nil + `.calibrating` until there are enough usable nights of HRV baseline, so we never fabricate a number.
    ///
    /// `strapRecoveryDays` are the days a strap (WHOOP / computed) already scored a recovery — those are SKIPPED
    /// so the strap keeps winning (matching the source precedence; we never overwrite a strap recovery with a
    /// lower-density watch one). Pure (no store) so it's unit-tested directly and is the SAME logic
    /// `analyzeRecent` ships. `appleRows` must be chronological (oldest first).
    nonisolated static func watchRecoveries(appleRows: [DailyMetric],
                                strapRecoveryDays: Set<String> = []) -> [WatchScoredDay] {
        let rows = appleRows.sorted { $0.day < $1.day }
        var out: [WatchScoredDay] = []
        for (i, row) in rows.enumerated() where !strapRecoveryDays.contains(row.day) {
            // Trailing baseline history = every earlier apple-health day with a usable value. Today is the
            // current row; the baseline is built from the days BEFORE it so it can't see its own value.
            let prior = rows[..<i]
            let sdnnHistory = prior.compactMap { $0.avgHrv }
            let rhrHistory = prior.compactMap { $0.restingHr.map(Double.init) }
            let res = WatchRecovery.compute(todaySDNN: row.avgHrv,
                                            todayRHR: row.restingHr,
                                            sdnnHistory: sdnnHistory,
                                            rhrHistory: rhrHistory)
            out.append(WatchScoredDay(day: row.day, recovery: res.recovery, confidence: res.confidence))
        }
        return out
    }

    /// Override a day's detected sleep aggregates with the user's hand-corrected window when one of the
    /// night's blocks was edited. Substitutes each edited block (matched by its stable startTs) for its
    /// detected twin and recomputes totalSleep / efficiency / stage minutes from the reshaped stages, so
    /// the Rest composite and recovery score the corrected sleep — not the auto-detected window. No edit
    /// touching the night → the detected daily is returned unchanged. (#318)
    private func sleepEditedDaily(_ daily: DailyMetric, detected: [CachedSleepSession],
                                 editsByStart: [Int: CachedSleepSession],
                                 habitualMidsleepSec: Int?) -> DailyMetric {
        guard !editsByStart.isEmpty else { return daily }
        let detectedTuples = detected.map { (startTs: $0.startTs, stagesJSON: $0.stagesJSON) }
        let editedStages = editsByStart.mapValues { $0.stagesJSON }
        // A hand-logged nap is a userEdited row with NO detected twin — it would never be
        // visited by the substitution pass, so its minutes were dropped from the day's Rest
        // total. Pass those twinless rows through the union channel so they fold in. (#518/#508)
        let detectedStarts = Set(detected.map { $0.startTs })
        let manualTuples = editsByStart
            .filter { !detectedStarts.contains($0.key) }
            .map { (startTs: $0.key, stagesJSON: $0.value.stagesJSON) }
        // #525/#547: supply each block's EFFECTIVE onset (audit finding C / #8) keyed by its stable
        // detected startTs, plus the device tz offset + learned habitual midsleep, so the edited recompute
        // picks the SAME MAIN NIGHT the Sleep tab shows. The onset must be the user-CORRECTED bedtime
        // (`startTsAdjusted ?? startTs`) when a block was edited, NOT the immutable detected start — a
        // bedtime edit crossing the overnight boundary would otherwise let the seam and the Sleep tab pick
        // different blocks. For a detected block the effective onset is its edited twin's effectiveStartTs
        // (an edit moves the onset) when edited, else the detected block's own effectiveStartTs; for a
        // twinless manual block it's that row's effectiveStartTs. Without these the seam falls back to the
        // legacy SUM and an overnight+nap day would re-include the nap in the headline total.
        var onsetByStart: [Int: Int] = [:]
        for d in detected {
            onsetByStart[d.startTs] = editsByStart[d.startTs]?.effectiveStartTs ?? d.effectiveStartTs
        }
        for (start, edit) in editsByStart where !detectedStarts.contains(start) {
            onsetByStart[start] = edit.effectiveStartTs
        }
        guard let r = SleepStageTotals.dailyAggregateHonoringEdits(detected: detectedTuples,
                                                                   edited: editedStages,
                                                                   manual: manualTuples,
                                                                   onsetByStart: onsetByStart,
                                                                   offsetSec: TimeZone.current.secondsFromGMT(),
                                                                   habitualMidsleepSec: habitualMidsleepSec),
              r.editApplied else { return daily }
        let agg = r.sleep
        return daily.with(totalSleepMin: agg.totalSleepMin, efficiency: agg.efficiency,
                          deepMin: agg.deepMin, remMin: agg.remMin, lightMin: agg.lightMin)
    }

    /// Re-derive the skin-temperature deviation (°C) for a night against the freshly-seeded personal
    /// baseline, mirroring the avgHrv→recovery re-score. Nil when the night had no wear-gated mean or
    /// the skin-temp baseline isn't usable yet (< minNightsSeed) — honest cold-start. Rounded to 2 dp
    /// to match the imported/demo precision. APPROXIMATE.
    private func recomputeSkinTempDev(_ nightly: Double?, _ base: BaselineState?) -> Double? {
        guard let v = nightly, let b = base, b.usable else { return nil }
        return (Baselines.deviation(v, state: b).delta * 100.0).rounded() / 100.0
    }

    /// The user's habitual midsleep (local time-of-day seconds), or nil under `habitualMinDays` of
    /// history (cold-start). Reads the stored sleep sessions (imported + computed) over the window, makes
    /// one `HistoryBlock` per session — start/end are the EFFECTIVE (edited) bounds so a corrected bedtime
    /// is learned, dayKey is the LOCAL calendar day of the midpoint — and defers to
    /// `SleepStageTotals.habitualMidsleepSec`, which keeps the longest block per day (naps drop out). The
    /// imported + computed sets can overlap; both are unioned and the learner de-dupes per day by length.
    /// (#547) Mirrors the Android `computeHabitualMidsleep`.
    /// CONSUME (#531 / H8): the prior pass's persisted v18 BAND sleep_state for sessions overlapping
    /// `[from, to]`, expanded to timestamped `(ts, state)` samples on the 30 s epoch grid, for the H7
    /// morning-stillness guard's re-onset confirmation. Reads the computed sessions in the window, then each
    /// one's persisted per-epoch sleep_state (NULL when never banded — first pass / imported night), and maps
    /// epoch `i` to `startTs + i*30`. Empty when nothing is banded yet, so the guard simply falls back to the
    /// HR bar. Honest: only real banded states are surfaced, never a fabricated reading. The grid here mirrors
    /// `SleepStager`'s 30 s epoch grid, so an epoch's timestamp lands inside the candidate run it scores.
    /// `nonisolated static` (FIX 1): touches only the `store` actor + value params, so the off-main scan
    /// loop calls it without hopping back to the main actor each iteration. Logic identical.
    nonisolated static func bandSleepStateSamples(computedId: String, from: Int, to: Int,
                                                  store: WhoopStore) async -> [(ts: Int, state: Int)] {
        let epochS = 30
        let sessions = (try? await store.sleepSessions(deviceId: computedId, from: from, to: to,
                                                       limit: 4000)) ?? []
        var samples: [(ts: Int, state: Int)] = []
        for s in sessions {
            guard let states = try? await store.sessionSleepState(deviceId: computedId,
                                                                  sessionStart: s.startTs),
                  !states.isEmpty else { continue }
            for (i, st) in states.enumerated() {
                samples.append((ts: s.startTs + i * epochS, state: st))
            }
        }
        return samples
    }

    private static func computeHabitualMidsleep(
        store: WhoopStore, importedId: String, computedId: String,
        windowStart: Int, windowEnd: Int, offsetSec: Int
    ) async -> Int? {
        let imported = (try? await store.sleepSessions(deviceId: importedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        let computed = (try? await store.sleepSessions(deviceId: computedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        let blocks = (imported + computed).compactMap { s -> SleepStageTotals.HistoryBlock? in
            let start = s.effectiveStartTs, end = s.endTs
            guard end > start else { return nil }
            let mid = start + (end - start) / 2
            let dayKey = AnalyticsEngine.dayString(mid, offsetSec: offsetSec)
            return SleepStageTotals.HistoryBlock(start: start, end: end, dayKey: dayKey)
        }
        return SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: offsetSec)
    }

    /// Floor a unix-seconds timestamp to 00:00:00 of its UTC calendar day. Mirrors the Android
    /// IntelligenceEngine.midnightUtc; the floorMod form is correct for any sign.
    nonisolated static func midnightUtc(_ ts: Int) -> Int { ts - floorMod(ts, 86_400) }

    /// Floor a unix-seconds timestamp to 00:00:00 of its LOCAL calendar day (#277). `offsetSec` is
    /// seconds EAST of UTC. Shift into local time, floor to the local day, shift back:
    /// `ts - floorMod(ts + offsetSec, 86400)`. floorMod keeps the floor correct for negative offsets
    /// and negative timestamps. `offsetSec == 0` reduces exactly to `midnightUtc`. Mirrors the
    /// Android IntelligenceEngine.midnightLocal byte-for-byte.
    nonisolated static func midnightLocal(_ ts: Int, offsetSec: Int) -> Int {
        ts - floorMod(ts + offsetSec, 86_400)
    }

    /// Euclidean modulo (result has the sign of the divisor) — matches Kotlin/Java Math.floorMod, so
    /// the LOCAL-midnight floor is identical across platforms for any sign of ts/offset. Swift's `%`
    /// is a remainder (sign of the dividend), which would mis-floor negative inputs.
    nonisolated private static func floorMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
    }
}

private extension DailyMetric {
    /// Rebuild the immutable DailyMetric with a substituted recovery + skin-temp deviation
    /// (the struct has no `copy()`). (#78)
    func with(recovery r: Double?, skinTempDevC sd: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: r, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: sd, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst)
    }

    /// Rebuild with substituted sleep-derived fields (a user-corrected wake window), leaving every
    /// non-sleep field untouched. Used by `sleepEditedDaily` so Rest/recovery score the edited sleep. (#318)
    func with(totalSleepMin tsm: Double?, efficiency eff: Double?,
              deepMin dm: Double?, remMin rm: Double?, lightMin lm: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: tsm, efficiency: eff, deepMin: dm, remMin: rm, lightMin: lm,
                    disturbances: disturbances, restingHr: restingHr, avgHrv: avgHrv, recovery: recovery,
                    strain: strain, exerciseCount: exerciseCount, spo2Pct: spo2Pct,
                    skinTempDevC: skinTempDevC, respRateBpm: respRateBpm, steps: steps,
                    activeKcalEst: activeKcalEst)
    }
}
