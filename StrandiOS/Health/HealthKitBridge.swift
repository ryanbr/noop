#if os(iOS)
import Foundation
import HealthKit
import WhoopStore
import StrandAnalytics
import StrandImport

/// Two-way Apple Health bridge for the iOS app.
///
/// iOS has HealthKit (macOS does not), so the iOS target can do far more than parse a static export:
/// it reads the user's own Health data live and maps it onto the **same** `WhoopStore` rows the
/// macOS importer produces (under the `apple-health` source id), and it writes NOOP-computed metrics
/// back into Apple Health. Everything stays on-device and strictly opt-in.
@MainActor
final class HealthKitBridge: ObservableObject {

    enum AuthState: Equatable {
        case unknown, unavailable, denied, authorized
        /// The build can't talk to HealthKit at all: it was re-signed (free Apple ID / AltStore /
        /// Sideloadly) WITHOUT the `com.apple.developer.healthkit` entitlement, so the framework is
        /// present but the app can never read/write Health and can never appear under
        /// Settings › Health › Data Access & Devices. Distinct from `.denied` (entitled build, user
        /// said no) and `.unavailable` (no HealthKit hardware) so the UI can route to the honest
        /// file/Shortcuts import path instead of giving impossible Settings instructions (#348).
        case entitlementMissing
    }

    @Published private(set) var auth: AuthState = .unknown
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    /// The most recent failure surfaced by `sync` / `writeBack`. Cleared on a successful run. UI binds
    /// here so an Apple Health auth revoke, quota hit, or invalid sample is visible instead of silent.
    @Published private(set) var lastError: String?

    /// Whether the user has opted into the body-composition READ import (#653). Unlike the write-back
    /// stages below, HealthKit never reveals read-grant status, so there is no live signal to check —
    /// NOOP tracks its own "the user asked for this" bit and gates `sync()`'s body-composition reads on
    /// it, so a category the user never turned on is neither requested from HealthKit nor read even if
    /// (somehow) already authorized. See `isHeartRateWritebackAuthorized` / `isWorkoutWritebackAuthorized`
    /// for the two write-back stages, whose granted state IS observable and so needs no persisted flag.
    @Published private(set) var bodyCompositionEnabled: Bool
    /// Bumped after every staged `request*Authorization` call so SwiftUI re-evaluates the two live
    /// `is*WritebackAuthorized` computed properties below (they read `store.authorizationStatus`
    /// directly, which isn't itself `@Published` and so wouldn't otherwise trigger a re-render).
    @Published private(set) var authRefreshTick = 0

    private let store = HKHealthStore()
    private let repo: Repository
    /// Source id imported HealthKit data lands under (matches `AppModel.appleDeviceId`).
    private let appleDeviceId: String
    /// NOOP's own strap-derived source id, read back when writing into Health.
    private let noopDeviceId: String
    /// NOOP's on-device COMPUTED daily scores (recovery/HRV/RHR/SpO₂/resp) live under the sibling
    /// `deviceId + "-noop"` id — mirrors `Repository.computedDeviceId` / `IntelligenceEngine.computedId`.
    /// `writeBack` must read this, not the raw import id: a Bluetooth-only WHOOP user has no imported
    /// `noopDeviceId` daily row, so those metrics exist ONLY here.
    private var computedDeviceId: String { noopDeviceId + "-noop" }

    init(repo: Repository, appleDeviceId: String, noopDeviceId: String) {
        self.repo = repo
        self.appleDeviceId = appleDeviceId
        self.noopDeviceId = noopDeviceId

        // #653 migration: a pre-existing install that already completed the OLD bundled "Enable Apple
        // Health" flow (which requested body-composition reads together with everything else, in one
        // sheet) keeps seeing that data instead of it silently vanishing behind a new, unset toggle. A
        // genuinely new install has nothing granted yet, so it defaults OFF like every other new staged
        // toggle here — matching the explicit-opt-in spirit of #653 rather than assuming consent.
        // Detected via the SAME legacy write-status signal `refreshAuthIfPreviouslyGranted` resumes off
        // of (HealthKit exposes share/write status reliably; it never exposes read status at all, which
        // is exactly why this needs its own persisted flag instead of a live check like the write-back
        // stages below).
        let bodyCompKey = HealthKitBridge.bodyCompositionDefaultsKey
        if let stored = UserDefaults.standard.object(forKey: bodyCompKey) as? Bool {
            self.bodyCompositionEnabled = stored
        } else {
            let migrated = HealthKitBridge.nightlyVitalsWriteTypesGranted(store: HKHealthStore())
            self.bodyCompositionEnabled = migrated
            UserDefaults.standard.set(migrated, forKey: bodyCompKey)
        }

        // Order matters: a free-signed build with no HealthKit entitlement is dead in the water even
        // where the hardware supports Health, so surface that first. `.unavailable` (no HealthKit at
        // all, e.g. iPad without the framework) still wins where it applies because we only reach the
        // entitlement check when `isHealthDataAvailable()` is true.
        if !HKHealthStore.isHealthDataAvailable() {
            auth = .unavailable
        } else if !HealthKitBridge.hasHealthKitEntitlement {
            auth = .entitlementMissing
        }
    }

    // MARK: - Types (#653: staged consent — see the enum + read/write accessors below)

    /// One independently-consented Apple Health scope. Splitting the single "Enable Apple Health"
    /// prompt — which used to ask for every read AND write type NOOP touches, in one system sheet —
    /// into stages the user opts into individually, each explicit about what it reads/writes BEFORE its
    /// own HealthKit prompt fires. `coreRead` + `nightlyVitalsWriteback` are still requested together as
    /// the primary "Enable Apple Health" action (`requestAuthorization()`, unchanged in name/signature so
    /// both existing call sites keep compiling) — that pairing is what already fed Charge/Rest/Effort
    /// scores before this change, so it stays the one-tap default. `bodyComposition`,
    /// `heartRateWriteback`, and `workoutWriteback` are additional, narrower asks a user opts into
    /// separately once connected. Every existing PER-FEATURE authorization guard (`writeVitals` checking
    /// each vital's own share status, `writeHeartRate` / `writeWorkouts` checking theirs) is UNCHANGED —
    /// staging only changes what gets requested and when, never what's checked before a write.
    private enum ConsentStage {
        case coreRead, bodyComposition, nightlyVitalsWriteback, heartRateWriteback, workoutWriteback
    }

    // Every id here ends up in the HealthKit permission dialog for its stage. Only request what `sync`
    // actually aggregates into `DayAgg` (coreRead) / what each write-back feature actually writes; adding
    // scopes a feature never consumes makes the consent prompt noisier and surfaces a privacy ask we
    // don't honour.
    private static let coreReadIds: [HKQuantityTypeIdentifier] = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation,
        .respiratoryRate, .bodyTemperature, .stepCount, .activeEnergyBurned,
        .basalEnergyBurned, .vo2Max,
    ]
    /// Body composition — READ-ONLY (#20), and its own opt-in stage (#653): imported under the
    /// apple-health source like the file importer already ingests, but never in any write-type set.
    private static let bodyCompositionReadIds: [HKQuantityTypeIdentifier] = [
        .bodyMass, .bodyFatPercentage, .leanBodyMass, .bodyMassIndex
    ]
    /// The nightly vitals write-back set (#653's "core nightly vitals writeback" stage). Identical to
    /// the set pre-#653 installs already granted under the old bundled flow, so
    /// `refreshAuthIfPreviouslyGranted` / the init-time body-composition migration above can both resume
    /// off it unchanged.
    private static let nightlyVitalsWriteIds: [HKQuantityTypeIdentifier] = [
        .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation, .respiratoryRate
    ]
    /// The continuous 1-minute heart-rate stream write-back — its own opt-in stage (#653).
    private static let heartRateWriteId: HKQuantityTypeIdentifier = .heartRate
    /// The energy/distance samples attached to written workouts — bundled with the workout write-back
    /// stage (#653), since neither means anything without the workout it's attached to.
    private static let workoutEnergyDistanceWriteIds: [HKQuantityTypeIdentifier] = [
        .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling
    ]

    /// The read types HealthKit should be asked for on behalf of `stage`; empty for a write-only stage.
    private func readTypes(for stage: ConsentStage) -> Set<HKObjectType> {
        switch stage {
        case .coreRead:
            var s = Set<HKObjectType>()
            for id in HealthKitBridge.coreReadIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
            if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
            s.insert(HKObjectType.workoutType())
            return s
        case .bodyComposition:
            var s = Set<HKObjectType>()
            for id in HealthKitBridge.bodyCompositionReadIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
            return s
        case .nightlyVitalsWriteback, .heartRateWriteback, .workoutWriteback:
            return []
        }
    }

    /// The share (write) types HealthKit should be asked for on behalf of `stage`; empty for a
    /// read-only stage.
    private func writeTypes(for stage: ConsentStage) -> Set<HKSampleType> {
        switch stage {
        case .coreRead, .bodyComposition:
            return []
        case .nightlyVitalsWriteback:
            var s = Set<HKSampleType>()
            for id in HealthKitBridge.nightlyVitalsWriteIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
            if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
            return s
        case .heartRateWriteback:
            var s = Set<HKSampleType>()
            if let t = HKObjectType.quantityType(forIdentifier: HealthKitBridge.heartRateWriteId) { s.insert(t) }
            return s
        case .workoutWriteback:
            var s = Set<HKSampleType>()
            for id in HealthKitBridge.workoutEnergyDistanceWriteIds {
                if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) }
            }
            s.insert(HKObjectType.workoutType())
            return s
        }
    }

    /// Self-free helper (usable from `init`, before every stored property is set) for whether the
    /// nightly-vitals write types are ALL already `.sharingAuthorized` — the one signal HealthKit gives
    /// us reliably, and the same one `refreshAuthIfPreviouslyGranted` resumes `auth` off of.
    private static func nightlyVitalsWriteTypesGranted(store: HKHealthStore) -> Bool {
        var s = Set<HKSampleType>()
        for id in nightlyVitalsWriteIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        return s.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized }
    }

    /// UserDefaults key for the persisted body-composition read opt-in (#653).
    private static let bodyCompositionDefaultsKey = "hkBodyCompositionReadEnabled.v1"

    /// Live HealthKit signal for whether the continuous-HR write-back stage is granted. No persisted
    /// flag needed — unlike the two read-only stages, HealthKit reliably reports SHARE status, and the
    /// existing `writeHeartRate` guard already checks this exact type before ever writing.
    var isHeartRateWritebackAuthorized: Bool {
        _ = authRefreshTick   // re-evaluated whenever a staged request completes; see the property's doc.
        guard let type = HKQuantityType.quantityType(forIdentifier: HealthKitBridge.heartRateWriteId) else { return false }
        return store.authorizationStatus(for: type) == .sharingAuthorized
    }

    /// Live HealthKit signal for whether the workout write-back stage is granted (workout share type
    /// specifically — the same one `writeWorkouts` already gates on before ever writing).
    var isWorkoutWritebackAuthorized: Bool {
        _ = authRefreshTick
        return store.authorizationStatus(for: .workoutType()) == .sharingAuthorized
    }

    /// Turn the body-composition READ stage on (requesting HealthKit access if needed) or off (just the
    /// local flag — HealthKit has no API to revoke a granted read type from inside the app, so "off"
    /// here means "NOOP stops asking for/using it going forward", not "access is rescinded").
    func setBodyCompositionEnabled(_ enabled: Bool) {
        if enabled {
            Task { await requestBodyCompositionAuthorization() }
        } else {
            bodyCompositionEnabled = false
            UserDefaults.standard.set(false, forKey: HealthKitBridge.bodyCompositionDefaultsKey)
        }
    }

    /// Request the body-composition read stage (#653). Requires the core stage to already be enabled —
    /// this is presented as an "extra" once connected, not a standalone first step. A successful request
    /// (sheet shown, regardless of what the user then picks — HealthKit never reveals read decisions,
    /// same philosophy as `requestAuthorization()`) flips the persisted flag on so `sync()` starts
    /// reading these types.
    func requestBodyCompositionAuthorization() async {
        guard auth == .authorized else { return }
        do {
            try await store.requestAuthorization(toShare: writeTypes(for: .bodyComposition), read: readTypes(for: .bodyComposition))
            bodyCompositionEnabled = true
            UserDefaults.standard.set(true, forKey: HealthKitBridge.bodyCompositionDefaultsKey)
        } catch {
            // Leave the flag as it was — a thrown request here means a genuine system-level failure
            // (see `requestAuthorization()`'s doc), not a user decline, so there's nothing to roll back.
        }
    }

    /// Request the continuous heart-rate write-back stage (#653). `writeHeartRate` already checks this
    /// exact type's share status before writing, so nothing else needs to change once granted.
    func requestHeartRateWriteback() async {
        guard auth == .authorized else { return }
        try? await store.requestAuthorization(toShare: writeTypes(for: .heartRateWriteback), read: [])
        authRefreshTick += 1
    }

    /// Request the workout (+ energy/distance) write-back stage (#653). `writeWorkouts` already checks
    /// the workout type's share status before writing, so nothing else needs to change once granted.
    func requestWorkoutWriteback() async {
        guard auth == .authorized else { return }
        try? await store.requestAuthorization(toShare: writeTypes(for: .workoutWriteback), read: [])
        authRefreshTick += 1
    }

    // MARK: - Authorization

    /// Request read + write permission. HealthKit never reveals whether *read* was granted, so we
    /// treat a successful request as `.authorized` and let queries return empty if the user declined.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { auth = .unavailable; return }
        // A free-signed build (no `com.apple.developer.healthkit` entitlement) can NEVER reach Health:
        // `requestAuthorization` either throws "Missing application-identifier"/"missing entitlement"
        // or returns without ever presenting the sheet and leaves every type `.notDetermined`. Either
        // way the honest answer is "this build can't use Apple Health directly", NOT "you denied it" —
        // so never fall through to `.denied` (which tells the user to fix it in Settings, where the app
        // can never appear). Detect via the embedded provisioning profile up front (#348).
        guard HealthKitBridge.hasHealthKitEntitlement else { auth = .entitlementMissing; return }
        do {
            // #653: the primary "Enable Apple Health" ask is narrowed to core reads + the nightly
            // vitals write-back — the pairing that already fed Charge/Rest/Effort scores. Continuous
            // heart rate, workouts, and body composition are separate, narrower asks (see
            // `requestHeartRateWriteback` / `requestWorkoutWriteback` / `requestBodyCompositionAuthorization`)
            // a user opts into afterward, each explicit about its own scope before its own prompt fires.
            try await store.requestAuthorization(toShare: writeTypes(for: .nightlyVitalsWriteback), read: readTypes(for: .coreRead))
            // The entitlement is present (the guard above proved it via the embedded profile, or there's
            // no profile = App Store build), so a successful request means the bridge is usable. We do
            // NOT reclassify to `.entitlementMissing` off the post-request `.notDetermined` heuristic
            // here: on a genuinely-entitled build the user could grant only reads (writes stay
            // `.notDetermined`) or dismiss the share sheet, and that must stay `.authorized` with the
            // normal Settings guidance — never the file-import reroute. The provisioning-profile check is
            // the authoritative signal; the `.notDetermined` fallback only matters when that check can't
            // run, which on iOS means an App Store build that by definition has the entitlement.
            auth = .authorized
        } catch {
            // A thrown error here is on a build that carries the entitlement (guarded above), so it's a
            // genuine denial / request failure — keep the normal `.denied` "enable in Settings" path,
            // never the entitlement-missing reroute.
            auth = .denied
        }
        // First successful grant in this process: arm the live HealthKit stream so a watch-only user
        // gets continuous ingestion (new SDNN/RHR/sleep/etc. land within the hour) instead of only on
        // app foreground. Guarded inside enableLiveDelivery on auth == .authorized, so the .denied path
        // above is a no-op.
        enableLiveDelivery()
    }

    /// Resume a prior grant on launch without re-prompting. `auth` is a fresh `.unknown` every
    /// process (the bridge isn't persisted), so a user who already enabled Apple Health would
    /// otherwise have to re-tap "Enable" each session before the scenePhase sync runs. HealthKit
    /// never reveals *read* status, but *write*/share status is observable — if the user already
    /// authorized all of our write types, treat the bridge as `.authorized`. This only reads
    /// status, so no system permission sheet is shown.
    func refreshAuthIfPreviouslyGranted() {
        guard auth == .unknown, HKHealthStore.isHealthDataAvailable() else { return }
        let granted = HealthKitBridge.nightlyVitalsWriteTypesGranted(store: store)
        if granted {
            auth = .authorized
            // A returning user who already granted access should get the live stream re-armed for this
            // process. enableLiveDelivery is idempotent (HealthKit dedups observers + background
            // delivery per type), so calling it here as well as after a fresh requestAuthorization is safe.
            enableLiveDelivery()
            // #653: no more silent auto-reprompt for newly-added share types here. Continuous heart
            // rate and workout write-back are now their own explicit, user-initiated toggles
            // (`requestHeartRateWriteback` / `requestWorkoutWriteback`) — a returning user who already
            // granted those under the old bundled flow keeps them (HealthKit's grant is untouched by
            // this change; `writeHeartRate` / `writeWorkouts` still gate on the live share status), but
            // nothing here asks HealthKit for anything new on their behalf without a tap.
        }
    }

    // MARK: - Live delivery (continuous ingestion)

    /// The scored read types we want a live observer + hourly background delivery on. This is the
    /// subset of `coreReadIds` (plus sleep) that actually feeds Charge/Rest/Effort/Fitness Age, so
    /// a watch-only user's numbers refresh on their own rather than only when the app is foregrounded.
    /// We deliberately do NOT observe the body-composition reads (weight/BMI/etc.) — those don't move a
    /// score and a manual weigh-in shouldn't wake the app every hour.
    private static let liveQuantityIds: [HKQuantityTypeIdentifier] = [
        .heartRateVariabilitySDNN, .restingHeartRate, .activeEnergyBurned, .heartRate, .vo2Max
    ]

    /// Long-lived observer queries, retained so HealthKit doesn't tear them down. Keyed by the sample
    /// type's identifier so a second `enableLiveDelivery()` call replaces rather than duplicates.
    private var observerQueries: [String: HKObserverQuery] = [:]

    /// Register one `HKObserverQuery` per scored read type and turn on hourly background delivery, so
    /// new Apple Watch data is ingested continuously. Each observer's update handler runs an anchored
    /// delta sync of just the affected window and then calls HealthKit's completion handler (required —
    /// HealthKit stops delivering to an observer that never acknowledges). Idempotent and guarded behind
    /// `auth == .authorized`; safe to call from several entry points.
    func enableLiveDelivery() {
        guard auth == .authorized, HKHealthStore.isHealthDataAvailable() else { return }

        var types: [HKSampleType] = []
        for id in HealthKitBridge.liveQuantityIds {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.append(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.append(sleep) }

        for type in types {
            let key = type.identifier
            // Tear down a prior observer for this type before re-registering, so a re-arm (e.g. a
            // returning user hitting both requestAuthorization and refreshAuthIfPreviouslyGranted) can
            // never leave two live observers fighting over the same completion handler.
            if let existing = observerQueries[key] {
                store.stop(existing)
                observerQueries[key] = nil
            }
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                // HealthKit invokes this on a background queue. Hop to the main actor (the bridge is
                // @MainActor and `sync` mutates published state), run the incremental catch-up, then
                // ALWAYS call completion so HealthKit keeps delivering. We don't tie completion to sync
                // success: a transient store error shouldn't make HealthKit think we never handled the
                // update and back off — the next foreground catch-up will reconcile.
                guard let self else { completion(); return }
                Task { @MainActor in
                    await self.syncFromObserver(type: type)
                    completion()
                }
            }
            store.execute(observer)
            observerQueries[key] = observer

            // Hourly is the finest cadence HealthKit honours for most types and is plenty for daily
            // aggregate scores. Failure here is non-fatal: the foreground catch-up still backfills.
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    /// Foreground catch-up. Call on app-active so anything background delivery missed (the system can
    /// throttle or skip wakes) is backfilled. A short window is enough because live delivery keeps the
    /// recent days current; 7 covers a weekend of missed wakes. Exposed for the existing scenePhase
    /// hook in `StrandiOSApp` to call — no other file is edited.
    func foregroundCatchUp() async {
        await sync(days: 7)
    }

    /// Drive an incremental sync off an observer wake. We use an `HKAnchoredObjectQuery` per type to
    /// learn the span of days touched since we last looked (persisting the anchor so the same samples
    /// aren't walked twice and nothing between wakes is missed), then re-aggregate just that day window
    /// via the existing `sync(days:)` path. Re-aggregating the window (rather than the deltas alone)
    /// keeps every per-day average correct and idempotent — `sync` upserts are keyed by day.
    private func syncFromObserver(type: HKSampleType) async {
        guard auth == .authorized else { return }
        let touched = await fetchTouchedDayWindow(type: type)
        // No new samples since the last anchor (a spurious wake): nothing to do.
        guard let touched else { return }
        let cal = Calendar.current
        let daysBack = cal.dateComponents([.day], from: cal.startOfDay(for: touched),
                                          to: cal.startOfDay(for: Date())).day ?? 0
        // Clamp to a sane window: at least today, and never re-walk more than a month from one wake.
        let window = max(1, min(31, daysBack + 1))
        await sync(days: window)
    }

    /// Advance this type's stored anchor over any new samples and return the OLDEST sample date seen,
    /// or nil when there were no new samples. Anchors are persisted in UserDefaults per type so live
    /// deltas are neither re-ingested nor missed across launches. We don't consume the samples here —
    /// `sync(days:)` re-reads the aggregate for the affected window — the anchor's only job is to tell
    /// us how far back the change reached.
    private func fetchTouchedDayWindow(type: HKSampleType) async -> Date? {
        let key = HealthKitBridge.anchorDefaultsKey(for: type)
        let priorAnchor: HKQueryAnchor? = {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }()

        return await withCheckedContinuation { (cont: CheckedContinuation<Date?, Never>) in
            let q = HKAnchoredObjectQuery(
                type: type, predicate: Self.notNoopAuthored,
                anchor: priorAnchor, limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, _ in
                // Persist the advanced anchor so the next wake only sees genuinely-new samples. Skip the
                // write on a query error (newAnchor nil) so we don't blow away a good cursor.
                if let newAnchor,
                   let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
                    UserDefaults.standard.set(data, forKey: key)
                }
                let oldest = (samples ?? []).map { $0.startDate }.min()
                cont.resume(returning: oldest)
            }
            store.execute(q)
        }
    }

    /// UserDefaults key for a type's persisted HealthKit anchor. Namespaced so it can't collide with
    /// other app defaults, and keyed by the stable HK identifier so it survives across launches.
    private static func anchorDefaultsKey(for type: HKSampleType) -> String {
        "hkAnchor.v1.\(type.identifier)"
    }

    // MARK: - Read → store

    /// Pull the last `days` of Apple Health into the on-device store under the `apple-health` source,
    /// then write NOOP's own computed metrics back into Health. Safe to call repeatedly (idempotent
    /// upserts keyed by day).
    func sync(days: Int = 30) async {
        guard auth == .authorized, !syncing else { return }
        syncing = true
        defer { syncing = false }
        guard let store = await repo.storeHandle() else { return }

        let cal = Calendar.current
        let end = Date()
        guard let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: end)) else { return }

        var byDay: [String: DayAgg] = [:]
        func agg(_ day: String) -> DayAgg { byDay[day] ?? DayAgg() }

        // Quantity aggregates per day.
        await collect(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.restingHr = v; byDay[day] = a
        }
        await collect(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.avgHr = v; byDay[day] = a
        }
        await collect(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteMax) { day, v in
            var a = agg(day); a.maxHr = v; byDay[day] = a
        }
        await collect(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.hrv = v; byDay[day] = a
        }
        await collect(.oxygenSaturation, unit: .percent(), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.spo2 = v * 100; byDay[day] = a   // 0…1 → percent
        }
        await collect(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.respRate = v; byDay[day] = a
        }
        await collect(.stepCount, unit: .count(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.steps = v; byDay[day] = a
        }
        await collect(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.activeKcal = v; byDay[day] = a
        }
        await collect(.basalEnergyBurned, unit: .kilocalorie(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.basalKcal = v; byDay[day] = a
        }
        await collect(.vo2Max, unit: HKUnit(from: "ml/kg*min"), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.vo2max = v; byDay[day] = a
        }

        // Body composition — READ-ONLY import under the apple-health source (#20), and its own opt-in
        // stage (#653): gated on `bodyCompositionEnabled` so a user who never turned this stage on gets
        // no reads here even if some stray grant existed — the toggle, not HealthKit's opaque read
        // status, is the source of truth for whether this runs. Weight, lean mass and BMI are
        // point-in-time readings, so take the latest-of-day; body-fat reads fine as a daily average.
        // Body-fat HealthKit gives a 0…1 fraction, scaled to percent like spo2 above.
        if bodyCompositionEnabled {
            await collect(.bodyMass, unit: .gramUnit(with: .kilo), start: start, end: end, op: .discreteMostRecent) { day, v in
                var a = agg(day); a.weightKg = v; byDay[day] = a
            }
            await collect(.bodyFatPercentage, unit: .percent(), start: start, end: end, op: .discreteAverage) { day, v in
                var a = agg(day); a.bodyFatPct = v * 100; byDay[day] = a   // 0…1 → percent
            }
            await collect(.leanBodyMass, unit: .gramUnit(with: .kilo), start: start, end: end, op: .discreteMostRecent) { day, v in
                var a = agg(day); a.leanMassKg = v; byDay[day] = a
            }
            await collect(.bodyMassIndex, unit: .count(), start: start, end: end, op: .discreteMostRecent) { day, v in
                var a = agg(day); a.bmi = v; byDay[day] = a
            }
        }

        // Sleep minutes per day (asleep stages summed; attributed to wake day).
        await collectSleep(start: start, end: end) { day, asleepMin, deepMin, remMin, coreMin in
            var a = agg(day)
            a.asleepMin = asleepMin; a.deepMin = deepMin; a.remMin = remMin; a.coreMin = coreMin
            byDay[day] = a
        }

        // Build + upsert the store rows under the apple-health source.
        let appleRows = byDay.map { (day, a) in
            AppleDaily(day: day, steps: a.steps.map { Int($0) },
                       activeKcal: a.activeKcal, basalKcal: a.basalKcal, vo2max: a.vo2max,
                       avgHr: a.avgHr.map { Int($0.rounded()) }, maxHr: a.maxHr.map { Int($0.rounded()) },
                       walkingHr: nil, weightKg: a.weightKg)
        }
        let dmRows = byDay.map { (day, a) in
            DailyMetric(day: day, totalSleepMin: a.asleepMin, efficiency: nil,
                        deepMin: a.deepMin, remMin: a.remMin, lightMin: a.coreMin, disturbances: nil,
                        restingHr: a.restingHr.map { Int($0.rounded()) }, avgHrv: a.hrv,
                        recovery: nil, strain: nil, exerciseCount: nil,
                        spo2Pct: a.spo2, skinTempDevC: nil, respRateBpm: a.respRate)
        }
        // Flatten to the generic metricSeries the shared Apple Health screen, the Today apple-health
        // sparklines, and the Metric Explorer read from — repo.series(key:source:"apple-health")
        // queries ONLY metricSeries, so without this every tile/chart renders "—" after a successful
        // sync. Reuse the importer's canonical key mapping so the keys match the macOS path exactly.
        // Body composition (weight/body_fat/lean_mass/bmi) now reads live on iOS (#20) and flows
        // through the same metricPoints keys as the file importer. iOS still doesn't collect
        // awake/in-bed minutes, so those stay nil and emit no points — correct.
        let aggregates = byDay.map { (day, a) in
            AppleDailyAggregate(
                day: day,
                restingHr: a.restingHr,
                hrvSDNN: a.hrv,
                spo2Pct: a.spo2,
                respRate: a.respRate,
                avgHr: a.avgHr,
                maxHr: a.maxHr,
                steps: a.steps,
                activeKcal: a.activeKcal,
                basalKcal: a.basalKcal,
                vo2max: a.vo2max,
                weightKg: a.weightKg,
                bodyFatPct: a.bodyFatPct,
                leanMassKg: a.leanMassKg,
                bmi: a.bmi,
                asleepMin: a.asleepMin,
                deepMin: a.deepMin,
                remMin: a.remMin,
                coreMin: a.coreMin
            )
        }
        let points = AppleHealthAggregator.metricPoints(aggregates)
            .map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }

        // Workouts the user logged in Apple Health (Apple Watch rings, gym apps, etc.). macOS already
        // imports these from a static Health export and Android reads them from Health Connect; iOS now
        // reads them live on-device too, so the platforms reach parity. ON-DEVICE ONLY: this is a plain
        // HealthKit read of workouts NOOP did NOT author, never any cloud/3rd-party API. (#835)
        let workoutRows = await collectWorkouts(start: start, end: end)

        // Persist all the apple-health rows AND write back, advancing lastSync only when the WHOLE
        // round-trip succeeds. The three read-side upserts used to be swallowed by `try?`, so a failed
        // import (e.g. a disk-full GRDB write) dropped rows yet still cleared lastError and advanced
        // lastSync — a false "success", and the next delta sync skipped the window. (Reimplemented
        // from @vulnix0x4's PR #375.)
        do {
            try await store.upsertAppleDaily(appleRows, deviceId: appleDeviceId)
            try await store.upsertDailyMetrics(dmRows, deviceId: appleDeviceId)
            try await store.upsertMetricSeries(points, deviceId: appleDeviceId)
            if !workoutRows.isEmpty { try await store.upsertWorkouts(workoutRows, deviceId: appleDeviceId) }
            try await writeBack(whoopStore: store)
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Write back (NOOP → Health)

    /// Write NOOP's strap-derived data into Apple Health: sleep sessions with full stage segments,
    /// the continuous 1-minute heart-rate stream, strap/manual workouts, and the nightly vitals
    /// (resting HR, HRV, SpO₂, respiratory rate) stamped at that day's wake time.
    ///
    /// Each feature saves independently and guards on ITS OWN type's share status, so one declined
    /// Health checkbox (or a save error) skips that feature without sinking the rest; the first error
    /// is rethrown at the end so `sync` still surfaces it in `lastError` without advancing `lastSync`.
    ///
    /// Dedup model (vitals): each emitted sample carries a deterministic `HKMetadataKeyExternalUUID`
    /// from `noopDeviceId + metric + day`. Before saving, we delete any of *our* prior samples that
    /// carry the same key (scoped to `HKSource.default()` so we never touch another app's data) and
    /// then save the fresh batch. HealthKit assigns a new UUID per save, so the previous strategy
    /// (no metadata, no delete) flooded Health with duplicates on every `sync()`.
    ///
    /// Throws on save failure so the caller can decide whether to advance `lastSync`.
    private func writeBack(whoopStore: WhoopStore, days: Int = 14) async throws {
        guard auth == .authorized else { return }
        let now = Date()
        guard let fromDate = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }
        let fromTs = Int(fromDate.timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)

        // Sleep sessions drive both the sleep write and the vitals' wake-time stamps: computed
        // sessions (deviceId + "-noop") first, imported rows override on startTs collision — the
        // same source precedence as the dailies union below and IntelligenceEngine's sleep reads.
        let computedSleeps = (try? await whoopStore.sleepSessions(deviceId: computedDeviceId, from: fromTs, to: nowTs, limit: 200)) ?? []
        let importedSleeps = (try? await whoopStore.sleepSessions(deviceId: noopDeviceId, from: fromTs, to: nowTs, limit: 200)) ?? []
        var sleepsByStart: [Int: CachedSleepSession] = [:]
        for s in computedSleeps { sleepsByStart[s.startTs] = s }
        for s in importedSleeps { sleepsByStart[s.startTs] = s }
        let sessions = sleepsByStart.keys.sorted().map { sleepsByStart[$0]! }

        var firstError: Error?
        func attempt(_ op: () async throws -> Void) async {
            do { try await op() } catch { if firstError == nil { firstError = error } }
        }
        await attempt { try await writeVitals(whoopStore: whoopStore, days: days, sessions: sessions) }
        await attempt { try await writeSleep(sessions: sessions) }
        await attempt { try await writeHeartRate(whoopStore: whoopStore, fromTs: fromTs, nowTs: nowTs) }
        await attempt { try await writeWorkouts(whoopStore: whoopStore, fromTs: fromTs, toTs: nowTs) }
        if let firstError { throw firstError }
    }

    /// The nightly vitals write (the original write-back), now stamped at the day's wake time when
    /// that day has a sleep session — a real timestamp inside the night the value describes, instead
    /// of a fabricated noon. Keys are unchanged, so re-stamped samples replace their noon ancestors.
    private func writeVitals(whoopStore: WhoopStore, days: Int, sessions: [CachedSleepSession]) async throws {
        let cal = Calendar.current
        let to = HealthKitBridge.dayString(Date())
        guard let fromDate = cal.date(byAdding: .day, value: -days, to: Date()) else { return }
        let from = HealthKitBridge.dayString(fromDate)

        // day (of wake) → wake instant. Ascending session order means the latest wake of a day wins,
        // matching collectSleep's end-date day attribution.
        var wakeByDay: [String: Date] = [:]
        for s in sessions where s.endTs > s.effectiveStartTs {
            let wake = Date(timeIntervalSince1970: TimeInterval(s.endTs))
            wakeByDay[HealthKitBridge.dayString(wake)] = wake
        }
        // Read NOOP's COMPUTED dailies (deviceId + "-noop"), which is the only place a strap-only
        // user's recovery/HRV/RHR/SpO₂/resp lives, then union with any imported `noopDeviceId` rows so
        // a user who ALSO imported a WHOOP export still gets the imported values. Imported overrides
        // computed per day, matching the dashboard's source precedence.
        let computed = (try? await whoopStore.dailyMetrics(deviceId: computedDeviceId, from: from, to: to)) ?? []
        let imported = (try? await whoopStore.dailyMetrics(deviceId: noopDeviceId, from: from, to: to)) ?? []
        var byDay: [String: DailyMetric] = [:]
        for r in computed { byDay[r.day] = r }   // computed first
        for r in imported { byDay[r.day] = r }   // imported overrides
        let rows = byDay.keys.sorted().map { byDay[$0]! }

        struct Candidate { let type: HKQuantityType; let key: String; let sample: HKQuantitySample }
        var candidates: [Candidate] = []
        func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, _ day: String, _ at: Date) {
            guard let type = HKQuantityType.quantityType(forIdentifier: id),
                  store.authorizationStatus(for: type) == .sharingAuthorized else { return }
            let key = "noop:\(noopDeviceId):\(id.rawValue):\(day)"
            let sample = HKQuantitySample(
                type: type,
                quantity: .init(unit: unit, doubleValue: value),
                start: at, end: at,
                metadata: [HKMetadataKeyExternalUUID: key]
            )
            candidates.append(Candidate(type: type, key: key, sample: sample))
        }

        for row in rows {
            guard let date = HealthKitBridge.date(from: row.day) else { continue }
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            let at = wakeByDay[row.day] ?? noon
            if let rhr = row.restingHr {
                add(.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), Double(rhr), row.day, at)
            }
            if let hrv = row.avgHrv {
                add(.heartRateVariabilitySDNN, .secondUnit(with: .milli), hrv, row.day, at)
            }
            if let spo2 = row.spo2Pct {
                add(.oxygenSaturation, .percent(), spo2 / 100, row.day, at)
            }
            if let rr = row.respRateBpm {
                add(.respiratoryRate, HKUnit.count().unitDivided(by: .minute()), rr, row.day, at)
            }
        }
        guard !candidates.isEmpty else { return }

        // Delete any of OUR prior samples that carry the same metadata keys, then write the fresh
        // batch. Scoped to HKSource.default() so we never touch a sample written by another app
        // that happens to use the same external UUID. Delete failures are non-fatal (e.g., nothing
        // to delete on first run) — only the save throws.
        let bySource = HKQuery.predicateForObjects(from: HKSource.default())
        let grouped = Dictionary(grouping: candidates, by: { $0.type })
        for (type, items) in grouped {
            let keys = Array(Set(items.map { $0.key }))
            let byKey = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                                    allowedValues: keys)
            let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, byKey])
            _ = try? await self.store.deleteObjects(of: type, predicate: pred)
        }
        try await self.store.save(candidates.map { $0.sample })
    }

    /// Write each BRIDGED NIGHT (#364) as one `.inBed` sample plus one category sample per stage
    /// segment (`deep → .asleepDeep`, `rem → .asleepREM`, `light → .asleepCore`, `wake → .awake`) —
    /// the same shape Oura and Apple Watch write, so Health renders the full hypnogram. A night the
    /// detector split on a brief mid-night wake exports as ONE entry whose gap is an explicit
    /// `.awake` segment (grouped by `SleepStageTotals.bridgedNightGroups`, the SAME bridge the daily
    /// totals score with, #561); naps never bridge and stay their own entries. Fragments whose
    /// `stagesJSON` carries no timing (the legacy aggregate-minutes shapes) get one honest
    /// `.asleepUnspecified` block instead of fabricated stage placement.
    ///
    /// Dedup: every sample of a night carries `HKMetadataKeyExternalUUID =
    /// noop:<deviceId>:sleep:<startTs>` keyed by the group's EARLIEST fragment's immutable detected
    /// onset (a user edit moves the span, never the key). The delete predicate carries EVERY
    /// fragment's key, so a night previously written as two entries fully clears when it becomes
    /// one; delete-then-write scoped to our own `HKSource`, like the vitals.
    private func writeSleep(sessions: [CachedSleepSession]) async throws {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        let blocks = sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) }
        let groups = SleepStageTotals.bridgedNightGroups(blocks, offsetSec: TimeZone.current.secondsFromGMT())
            .map { g in
                g.indices.map { i -> HealthWriteback.SleepFragment in
                    let s = sessions[i]
                    return .init(startTs: s.startTs, effectiveStartTs: s.effectiveStartTs,
                                 endTs: s.endTs, stagesJSON: s.stagesJSON)
                }
            }
        var samples: [HKCategorySample] = []
        var keys: [String] = []
        for entry in HealthWriteback.mergedSleepPlan(groups: groups) {
            let key = "noop:\(noopDeviceId):sleep:\(entry.keyStartTs)"
            let meta = [HKMetadataKeyExternalUUID: key]
            keys.append(contentsOf: entry.allKeyStartTs.map { "noop:\(noopDeviceId):sleep:\($0)" })
            samples.append(HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                            start: Date(timeIntervalSince1970: TimeInterval(entry.spanStart)),
                                            end: Date(timeIntervalSince1970: TimeInterval(entry.spanEnd)),
                                            metadata: meta))
            for seg in entry.intervals {
                let value: HKCategoryValueSleepAnalysis
                switch seg.kind {
                case .awake:       value = .awake
                case .light:       value = .asleepCore
                case .deep:        value = .asleepDeep
                case .rem:         value = .asleepREM
                case .unspecified: value = .asleepUnspecified
                }
                samples.append(HKCategorySample(
                    type: type, value: value.rawValue,
                    start: Date(timeIntervalSince1970: TimeInterval(seg.start)),
                    end: Date(timeIntervalSince1970: TimeInterval(seg.end)),
                    metadata: meta))
            }
        }
        guard !samples.isEmpty else { return }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: keys),
        ])
        _ = try? await store.deleteObjects(of: type, predicate: pred)
        try await store.save(samples)
    }

    /// UserDefaults key for the HR write cursor (the newest bucket ts we've written). Per-strap so a
    /// device switch restarts the backfill for the new strap instead of resuming mid-stream.
    private var hrWriteCursorKey: String { "hkHRWriteCursor.v1.\(noopDeviceId)" }

    /// Write the strap's continuous heart rate as 1-minute mean samples — the same `hrBuckets` SQL
    /// the charts read (measured-first, PPG fallback), so Health sees exactly what NOOP plots. Raw
    /// ~1 Hz is deliberately downsampled: a fully-worn day is ~86k samples, which bloats the Health
    /// store; 1/min matches Apple Watch's background cadence.
    ///
    /// Dedup: forward-only cursor plus a 48 h rewrite window. Each run deletes OUR OWN prior HR
    /// samples in `[windowStart, now]` (source-scoped, date-range predicate — far cheaper than per-
    /// sample external-UUID keys at this volume) and rewrites the window, so a strap offload that
    /// backfills a recent night reconciles. Offloads older than 48 h behind the cursor are missed
    /// until the cursor is cleared — accepted trade-off for not re-walking 14 days every sync.
    private func writeHeartRate(whoopStore: WhoopStore, fromTs: Int, nowTs: Int) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        let cursor = UserDefaults.standard.integer(forKey: hrWriteCursorKey)
        let windowStart = cursor > 0 ? max(fromTs, cursor - 48 * 3600) : fromTs
        let buckets = (try? await whoopStore.hrBuckets(deviceId: noopDeviceId, from: windowStart,
                                                       to: nowTs, bucketSeconds: 60)) ?? []
        guard !buckets.isEmpty else { return }

        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: TimeInterval(windowStart)),
                                        end: Date(timeIntervalSince1970: TimeInterval(nowTs) + 60),
                                        options: []),
        ])
        _ = try? await store.deleteObjects(of: type, predicate: pred)

        let unit = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKQuantitySample] = []
        samples.reserveCapacity(buckets.count)
        for b in buckets {
            let start = Date(timeIntervalSince1970: TimeInterval(b.ts))
            // Span the bucket, clamped so a bucket at the window edge can't end in the future
            // (HealthKit rejects future-dated samples).
            let end = Date(timeIntervalSince1970: TimeInterval(min(b.ts + 60, nowTs)))
            samples.append(HKQuantitySample(type: type,
                                            quantity: .init(unit: unit, doubleValue: b.bpm),
                                            start: start, end: max(start, end)))
        }
        // First run backfills ~20k samples (14 d × 1440/day); chunk the saves so no single HealthKit
        // transaction is oversized. Cursor only advances past what actually saved.
        var lastSaved = cursor
        var pending = samples[...]
        var pendingTs = buckets.map(\.ts)[...]
        while !pending.isEmpty {
            let chunk = Array(pending.prefix(5000))
            let chunkTs = Array(pendingTs.prefix(5000))
            pending = pending.dropFirst(chunk.count)
            pendingTs = pendingTs.dropFirst(chunk.count)
            try await store.save(chunk)
            lastSaved = max(lastSaved, chunkTs.last ?? lastSaved)
            UserDefaults.standard.set(lastSaved, forKey: hrWriteCursorKey)
        }
    }

    /// Write strap-detected and manual workouts into Health via `HKWorkoutBuilder`, with an
    /// `activeEnergyBurned` sample when the row has energy and a distance sample for distance
    /// sports. Workouts whose source is `apple-health` are EXCLUDED — those were imported FROM
    /// Health, and writing them back would duplicate the user's own Apple Watch/gym-app workouts.
    ///
    /// Dedup: `HKMetadataKeyExternalUUID = noop:<deviceId>:workout:<startTs>` in the workout
    /// metadata; delete-then-write scoped to our own source, like sleep and the vitals.
    private func writeWorkouts(whoopStore: WhoopStore, fromTs: Int, toTs: Int) async throws {
        guard store.authorizationStatus(for: .workoutType()) == .sharingAuthorized else { return }
        let mine = (try? await whoopStore.workouts(deviceId: noopDeviceId, from: fromTs, to: toTs, limit: 500)) ?? []
        let computed = (try? await whoopStore.workouts(deviceId: computedDeviceId, from: fromTs, to: toTs, limit: 500)) ?? []
        var byKey: [String: WorkoutRow] = [:]
        for w in computed + mine where w.source != HealthKitBridge.appleWorkoutSource {
            byKey["\(w.startTs):\(w.sport)"] = w
        }
        let rows = byKey.values.sorted { $0.startTs < $1.startTs }
        guard !rows.isEmpty else { return }

        func key(_ row: WorkoutRow) -> String { "noop:\(noopDeviceId):workout:\(row.startTs)" }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                        allowedValues: rows.map(key)),
        ])
        _ = try? await store.deleteObjects(of: .workoutType(), predicate: pred)

        for row in rows {
            let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(row.endTs))
            guard end > start else { continue }
            let config = HKWorkoutConfiguration()
            config.activityType = Self.activityType(forSport: row.sport)
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
            do {
                try await builder.beginCollection(at: start)
                try await builder.addMetadata([HKMetadataKeyExternalUUID: key(row)])
                var extras: [HKSample] = []
                if let kcal = row.energyKcal, kcal > 0,
                   let t = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                   store.authorizationStatus(for: t) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: t, quantity: .init(unit: .kilocalorie(), doubleValue: kcal),
                                                   start: start, end: end))
                }
                if let meters = row.distanceM, meters > 0,
                   let id = Self.distanceTypeId(forSport: row.sport),
                   let t = HKQuantityType.quantityType(forIdentifier: id),
                   store.authorizationStatus(for: t) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: t, quantity: .init(unit: .meter(), doubleValue: meters),
                                                   start: start, end: end))
                }
                if !extras.isEmpty { try await builder.addSamples(extras) }
                try await builder.endCollection(at: end)
                _ = try await builder.finishWorkout()
            } catch {
                builder.discardWorkout()
                throw error
            }
        }
    }

    /// Reverse of `sportName`: NOOP's sport label → the `HKWorkoutActivityType` written to Health.
    /// Labels the forward map collapses (e.g. boxing/kickboxing → "Boxing") reverse to the first
    /// member; unknown labels fall back to `.other`, never dropped.
    private static func activityType(forSport sport: String) -> HKWorkoutActivityType {
        if sport == LiftingImporter.sport { return .traditionalStrengthTraining }
        switch sport.lowercased() {
        case "running":       return .running
        case "walking":       return .walking
        case "hiking":        return .hiking
        case "cycling":       return .cycling
        case "hiit":          return .highIntensityIntervalTraining
        case "core training": return .coreTraining
        case "yoga":          return .yoga
        case "pilates":       return .pilates
        case "rowing":        return .rowing
        case "elliptical":    return .elliptical
        case "stairs":        return .stairClimbing
        case "jump rope":     return .jumpRope
        case "boxing":        return .boxing
        case "basketball":    return .basketball
        case "soccer":        return .soccer
        case "football":      return .americanFootball
        case "baseball":      return .baseball
        case "badminton":     return .badminton
        case "tennis":        return .tennis
        case "table tennis":  return .tableTennis
        case "volleyball":    return .volleyball
        case "squash":        return .squash
        case "martial arts":  return .martialArts
        case "dancing":       return .dance
        case "golf":          return .golf
        case "climbing":      return .climbing
        case "skiing":        return .downhillSkiing
        case "snowboarding":  return .snowboarding
        case "swimming":      return .swimming
        case "surfing":       return .surfingSports
        case "paddling":      return .paddleSports
        default:              return .other
        }
    }

    /// Which distance quantity a sport's `distanceM` maps to; nil for sports whose Health distance
    /// type NOOP doesn't request share access for (e.g. swimming).
    private static func distanceTypeId(forSport sport: String) -> HKQuantityTypeIdentifier? {
        switch sport.lowercased() {
        case "running", "walking", "hiking": return .distanceWalkingRunning
        case "cycling":                      return .distanceCycling
        default:                             return nil
        }
    }

    private struct DayAgg {
        var restingHr: Double?; var avgHr: Double?; var maxHr: Double?; var hrv: Double?
        var spo2: Double?; var respRate: Double?; var steps: Double?
        var activeKcal: Double?; var basalKcal: Double?; var vo2max: Double?
        var weightKg: Double?; var bodyFatPct: Double?; var leanMassKg: Double?; var bmi: Double?
        var asleepMin: Double?; var deepMin: Double?; var remMin: Double?; var coreMin: Double?
    }

    /// Excludes NOOP's own write-back samples from reads, so the two-way sync never reads its own
    /// output back in as "apple-health" data — which would make the strap and "Apple Health" plot the
    /// same line for a strap-only user, and bias the apple-health average for someone who also has a
    /// watch. `HKSource.default()` is this app's own source. (Reimplemented from @vulnix0x4's PR #375.)
    private static var notNoopAuthored: NSPredicate {
        NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()]))
    }

    private func collect(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date,
                         op: HKStatisticsOptions, sink: @escaping (String, Double) -> Void) async {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: start)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
            Self.notNoopAuthored,
        ])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: op, anchorDate: anchor,
                                                intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, _ in
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let q: HKQuantity?
                    switch op {
                    case .cumulativeSum:     q = stats.sumQuantity()
                    case .discreteAverage:   q = stats.averageQuantity()
                    case .discreteMax:       q = stats.maximumQuantity()
                    case .discreteMostRecent: q = stats.mostRecentQuantity()
                    default:                 q = stats.averageQuantity()
                    }
                    if let q { sink(HealthKitBridge.dayString(stats.startDate), q.doubleValue(for: unit)) }
                }
                cont.resume()
            }
            store.execute(q)
        }
    }

    private func collectSleep(start: Date, end: Date,
                              sink: @escaping (String, Double?, Double?, Double?, Double?) -> Void) async {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: []),
            Self.notNoopAuthored,
        ])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                var asleep: [String: Double] = [:], deep: [String: Double] = [:]
                var rem: [String: Double] = [:], core: [String: Double] = [:]
                for case let s as HKCategorySample in samples ?? [] {
                    let mins = s.endDate.timeIntervalSince(s.startDate) / 60
                    let day = HealthKitBridge.dayString(s.endDate)
                    switch s.value {
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                        deep[day, default: 0] += mins; asleep[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                        rem[day, default: 0] += mins; asleep[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        core[day, default: 0] += mins; asleep[day, default: 0] += mins
                    default:
                        break
                    }
                }
                for day in Set(asleep.keys) {
                    sink(day, asleep[day], deep[day], rem[day], core[day])
                }
                cont.resume()
            }
            store.execute(q)
        }
    }

    // MARK: - Workouts (#835)

    /// Read the workouts the user logged in Apple Health over `[start, end)` and map each to a
    /// `WorkoutRow` under the apple-health source. ON-DEVICE ONLY: a straight HealthKit `HKWorkout` query,
    /// no cloud or third-party API. NOOP-authored workouts are excluded (the same `notNoopAuthored`
    /// predicate the metric reads use) so our own write-back never re-imports as "Apple Health". Mirrors
    /// the macOS export importer and the Android Health Connect importer, which already ingest workouts,
    /// closing the iOS gap. The upsert is idempotent on (deviceId, startTs), so re-running a sync window
    /// refreshes rather than duplicates.
    private func collectWorkouts(start: Date, end: Date) async -> [WorkoutRow] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
            Self.notNoopAuthored,
        ])
        return await withCheckedContinuation { (cont: CheckedContinuation<[WorkoutRow], Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                var rows: [WorkoutRow] = []
                for case let workout as HKWorkout in samples ?? [] {
                    let startTs = Int(workout.startDate.timeIntervalSince1970)
                    let endTs = max(Int(workout.endDate.timeIntervalSince1970), startTs)
                    let duration = workout.duration > 0 ? workout.duration : Double(endTs - startTs)
                    rows.append(WorkoutRow(
                        startTs: startTs,
                        endTs: endTs,
                        sport: Self.sportName(workout.workoutActivityType),
                        source: HealthKitBridge.appleWorkoutSource,
                        durationS: duration,
                        energyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                        avgHr: nil,
                        maxHr: nil,
                        strain: nil,
                        distanceM: workout.totalDistance?.doubleValue(for: .meter()),
                        zonesJSON: nil,
                        notes: nil))
                }
                cont.resume(returning: rows)
            }
            store.execute(q)
        }
    }

    /// Source tag stamped on workouts imported from Apple Health. Matches the macOS importer's
    /// `WorkoutSource.appleHealthSource` ("apple-health") and `appleDeviceId`, so the workout list and
    /// source filters treat an iOS-read workout exactly like a macOS-imported one.
    static let appleWorkoutSource = "apple-health"

    /// Map an `HKWorkoutActivityType` to NOOP's human sport label. Strength training routes to the
    /// shared lifting sport so a gym session lands in the Lifting lane; anything we don't name explicitly
    /// falls back to a generic "Workout" rather than an opaque numeric type.
    private static func sportName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running:                    return "Running"
        case .walking:                    return "Walking"
        case .hiking:                     return "Hiking"
        case .cycling:                    return "Cycling"
        case .traditionalStrengthTraining,
             .functionalStrengthTraining: return LiftingImporter.sport
        case .highIntensityIntervalTraining: return "HIIT"
        case .coreTraining:               return "Core training"
        case .yoga:                       return "Yoga"
        case .pilates:                    return "Pilates"
        case .rowing:                     return "Rowing"
        case .elliptical:                 return "Elliptical"
        case .stairClimbing, .stairs:     return "Stairs"
        case .jumpRope:                   return "Jump rope"
        case .boxing, .kickboxing:        return "Boxing"
        case .basketball:                 return "Basketball"
        case .soccer:                     return "Soccer"
        case .americanFootball:           return "Football"
        case .baseball:                   return "Baseball"
        case .badminton:                  return "Badminton"
        case .tennis:                     return "Tennis"
        case .tableTennis:                return "Table tennis"
        case .volleyball:                 return "Volleyball"
        case .squash, .racquetball:       return "Squash"
        case .martialArts, .taiChi:       return "Martial arts"
        case .dance, .cardioDance, .socialDance: return "Dancing"
        case .golf:                       return "Golf"
        case .climbing:                   return "Climbing"
        case .downhillSkiing, .crossCountrySkiing: return "Skiing"
        case .snowboarding:               return "Snowboarding"
        case .swimming:                   return "Swimming"
        case .surfingSports:              return "Surfing"
        case .paddleSports:               return "Paddling"
        default:                          return "Workout"
        }
    }

    // MARK: - Entitlement detection (#348)

    /// True when this running build actually carries the `com.apple.developer.healthkit` entitlement —
    /// i.e. it can genuinely reach Apple Health. False for a free-Apple-ID / AltStore / Sideloadly
    /// re-sign, which strips the HealthKit capability: the framework links and `isHealthDataAvailable()`
    /// is still true, but `requestAuthorization` is a dead-end and the app can never appear under
    /// Settings › Health › Data Access & Devices.
    ///
    /// Resolution order (most authoritative first), mirroring `IOSDiagnostics`'s profile parse:
    ///  1. If an `embedded.mobileprovision` is present (every dev / sideloaded / TestFlight build ships
    ///     one), slice the wrapped XML plist and look for `com.apple.developer.healthkit` in its
    ///     `Entitlements` dict. A free re-sign re-writes this profile WITHOUT that key. This is the
    ///     definitive signal and is unaffected by whether the user later granted/denied permission.
    ///  2. No embedded profile → an App Store install (App Store strips it). Those are properly signed
    ///     with whatever capabilities the app declares, so treat the entitlement as PRESENT. This is the
    ///     conservative default: it never down-routes a legitimately-signed build, so a user who simply
    ///     denied permission keeps the normal Settings guidance rather than the file-import reroute.
    ///
    /// Computed once and cached: the bundle's profile can't change within a process lifetime.
    static let hasHealthKitEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            // No embedded profile = App Store build = properly signed. Assume present.
            return true
        }
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)) else {
            // Profile present but unparseable — don't claim a missing entitlement off a parse failure;
            // assume present so we never wrongly down-route a real build.
            return true
        }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return true
        }
        // The key is present (and truthy) on an entitled build; a free re-sign omits it entirely.
        return entitlements["com.apple.developer.healthkit"] != nil
    }()

    // MARK: - Date helpers

    // LOCAL civil day: the rest of the store keys days by the device-local civil day —
    // AppleHealthAggregator.localDay shifts each sample into its own offset, and
    // Repository.dayFormatter leaves timeZone at the default (local) zone. The
    // HKStatisticsCollectionQuery here already buckets in Calendar.current (anchor =
    // startOfDay, interval = 1 day), so labelling those local-midnight bucket starts with a
    // matching local formatter is strictly 1:1; using UTC instead mislabelled a full local day
    // under the previous UTC date for users east of UTC, so apple-health rows never merged with
    // the strap-computed/imported rows for the same civil day.
    // `nonisolated` so the HealthKit query completion handlers — which HealthKit invokes on a private
    // background queue (a nonisolated context) — can label day buckets without a main-actor-isolation
    // warning. They only read a thread-safe DateFormatter, so this is safe off the main actor.
    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current; return f
    }()
    nonisolated private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    nonisolated private static func date(from day: String) -> Date? { dayFormatter.date(from: day) }
}
#endif
