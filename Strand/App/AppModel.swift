import SwiftUI
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics
import StrandImport
#if os(iOS)
import UserNotifications
#endif

/// Data source currently running an import from the Data Sources screen.
enum DataSourceImportKind {
    case whoop
    case appleHealth
    case xiaomi
}

/// Root app state: owns the live BLE connection state and the CoreBluetooth engine.
/// More subsystems (Repository, AnalyticsEngine, ImportCoordinator) get wired in here
/// in later milestones.
@MainActor
final class AppModel: ObservableObject {
    /// The live instance, so an AppIntent (Shortcuts) can reach the bonded strap rather than spinning
    /// up a dead second AppModel (which would start a duplicate BLE engine and never buzz). Set in
    /// init(); `weak` so an intent fired while NOOP is closed sees nil and asks the user to open it. (#42)
    static weak var shared: AppModel?

    /// Timestamp formatter for the generic-HR strap-log lines routed through `straplog` into the shared
    /// log (issue #421). Mirrors `BLEManager.logTimeFormatter`'s `HH:mm:ss` so WHOOP and HR-strap lines
    /// read identically in the exported strap log.
    static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// The CANONICAL imported/computed id ("my-whoop"). The WHOOP-IMPORT target (`WhoopImporter`), the
    /// FusionSource `.whoopImport` mapping, and a manually-saved workout all land under THIS stable id, and
    /// the engine writes its computed scores under the matching `-noop` sibling. It must NOT follow the
    /// active strap (#814 union-model follow-up): a remove+re-add gives the strap a fresh "whoop-<uuid>" id,
    /// but if the import/computed target drifted to it, history banked earlier under "my-whoop" would be
    /// orphaned. The Repository's ACTIVE-strap read id follows the registry instead (`adoptActiveDevice`),
    /// and the dashboard reads the UNION of the two, so the re-added strap's live data AND the canonical
    /// history both surface. `let` because nothing moves it.
    let deviceId = "my-whoop"
    /// Source id for imported Apple Health data (stored beside Whoop for per-source pages + consensus).
    let appleDeviceId = "apple-health"
    /// Observable snapshot driven by the BLE engine (connection, HR, battery, log).
    let live: LiveState
    /// CoreBluetooth engine , scans, connects, bonds, streams.
    let ble: BLEManager
    /// Read model over the on-device store (dashboard + detail screens).
    let repo: Repository
    /// User profile (age/sex/body/HR-max) for zones, calories, baselines.
    let profile = ProfileStore()
    /// Behaviour settings: double-tap action, wear automation, zone coaching, smart alarm, illness watch.
    let behavior = BehaviorStore()
    /// On-device WHOOP-style recovery/strain/sleep computation from raw strap streams.
    let intelligence: IntelligenceEngine

    /// Opt-in AI coach (bring-your-own-key) , the one networked feature, off until the user enables it.
    let coach: AICoachEngine

    /// Observable cache over the paired-device registry; `activeDeviceId` drives the source coordinator.
    /// Built lazily once the store opens (see `wireSourceCoordinator`). nil until then , with no generic
    /// strap paired the active id stays "my-whoop", so this never affects the WHOOP startup path.
    /// `@Published` so the Devices screen re-renders the moment the registry is wired in (it observes
    /// `model.deviceRegistry`); nested `registry.$devices` changes are observed by the screen directly.
    @Published private(set) var deviceRegistry: DeviceRegistry?
    /// Runs exactly one device's live BLE at a time. DORMANT whenever WHOOP is active (the default and
    /// every no-strap case): it only acts when a non-WHOOP generic strap becomes the active device,
    /// pausing WHOOP and running the isolated `StandardHRSource`. nil until wired (post store-open).
    private(set) var sourceCoordinator: SourceCoordinator?

    /// Timestamps of moments marked via a double-tap (persisted).
    @Published var moments: [Date] = []

    /// Timestamps of "sleep marks" tapped on the strap (#461) , bedtime / wake / mid-night marks the
    /// user double-taps without screenshots or remembering the time. Persisted; each also writes a
    /// greppable "Sleep mark @ HH:mm" line into the strap log. Phase-1 foundation for tap-driven sleep
    /// bounds + personal sleep-stage calibration.
    @Published var sleepMarks: [Date] = []

    /// An in-progress manually-tracked workout (requested by users who want to start a session
    /// themselves rather than rely on auto-detection). Holds the start time + the live HR collected
    /// since; on End the window is scored via `StrainScorer` and saved as a `WorkoutRow` (source
    /// "manual"), which then shows in the Workouts view. The day's strain already counts this HR (it's
    /// the same live stream the store persists), so this is a per-session annotation, not a double-count.
    @Published var activeWorkout: ActiveWorkout?
    /// The just-ended workout, for a brief inline confirmation on Live (cleared on the next start).
    @Published var lastWorkout: WorkoutRow?

    /// Records the GPS route of an in-flight distance-type workout (run / ride / walk / hike) from
    /// CoreLocation (#524) , the Apple analogue of Android's `GpsSession` + foreground `LocationManager`.
    /// Fails safe: on a Mac with no GPS, or when location permission is denied, it records nothing and
    /// the session still banks HR + Effort without a route. Observed by the live workout card for live
    /// distance/pace; its final route is persisted on End via `RouteStore`, keyed by the saved row's
    /// natural key (the shared `WorkoutRow` has no route column on Apple). Default behaviour is opt-in by
    /// sport: it only arms for a `WorkoutCatalog.Sport.isDistanceSport`, and only actually captures once
    /// the user grants When-In-Use location.
    let gpsRecorder = GpsWorkoutRecorder()
    /// True while the active workout is a GPS-type session (drives the End-time route persist). Mirrors
    /// Android's `ActiveWorkout.gpsEnabled`.
    private var activeWorkoutIsGps = false

    /// A manual workout in progress. `samples` accumulate from the smoothed live `bpm`; `liveStrain`
    /// is recomputed as the window grows so the active card can show strain building in real time.
    struct ActiveWorkout: Equatable {
        let start: Date
        /// The named sport chosen at start (e.g. "Tennis", "Padel") , persisted as the saved row's
        /// `sport` so a live-tracked session keeps its label instead of the old generic "Workout".
        /// Defaults to the catalogue default ("Other") when started without a pick. (#519)
        var sport: String = WorkoutCatalog.defaultSportName
        var samples: [HRSample] = []
        var liveStrain: Double = 0
        var avgHr: Int = 0
        var peakHr: Int = 0
    }
    /// Illness/strain early-warning (recent RHR up + HRV down + skin-temp up vs baseline). nil = clear.
    @Published var healthAlert: String?

    // MARK: - v5 pillar snapshot (engines run in the analytics pass; the views read these)
    //
    // The Insights / skin-temp Health-hub cards take pure engine RESULTS by value. The analytics pass
    // (IntelligenceEngine.analyzeRecent → refreshV5Signals) computes them once from the stores and
    // publishes them here; AppModel exposes them so HealthView / InsightsHubView read a snapshot rather
    // than re-deriving. All opt-in / honest-nil , a nil result means "not enough data / not enabled".
    @Published var illnessSignal: IllnessSignalEngine.Result?
    /// Parallel Mahalanobis illness-distance read (IllnessDistance), computed on the SAME illness-ward
    /// z-vector as illnessSignal but NEVER gating the alert. The shipped IllnessSignalEngine stays the
    /// sole fire gate; this only surfaces a "how strong" confidence readout in the Heads-Up card when
    /// the engine has already raised. nil = not computed this pass. (Augment-only, Option A.)
    @Published var illnessDistance: IllnessDistance.Result?
    /// Cycle-phase awareness (only computed when the user has opted in; else nil). Awareness only.
    @Published var cyclePhase: CyclePhaseEngine.Result?
    /// The nightly fused-index curve (oldest→newest) feeding the cycle card's sparkline.
    @Published var cycleCurve: [Double] = []
    /// Body-clock phase estimate (circadian). nil until a usable activity profile exists.
    @Published var circadianPhase: CircadianEngine.PhaseEstimate?

    /// The L3 passive-nudge surface (haptic biofeedback "stress check-in"). The detector fires onto this
    /// from `evaluateStress`; both app roots inject it into the environment so the Breathe screen's card
    /// (and any host) surfaces the pending nudge. Owned here so the central hook can reach it. (v5 L3)
    let stressNudgeCenter = StressNudgeCenter()

    private var lastDoubleTapAt: Date = .distantPast
    private var lastCoachZone: Int = -1
    // L3 stress-onset detector state: a rolling R-R buffer + the replay-safe detector state (persisted
    // via BiofeedbackPrefs so a relaunch can't re-fire), carried verbatim between evaluations.
    private var rrBuf: [Int] = []
    private var stressState = BiofeedbackPrefs.loadStressState()

    /// Import source currently writing to the local store, if any.
    @Published private var activeImportSource: DataSourceImportKind?
    /// Last WHOOP export import result surfaced in the WHOOP card.
    @Published var whoopImportSummary: String?
    /// Last Apple Health import result surfaced in the Apple Health card.
    @Published var appleHealthImportSummary: String?
    /// Last Xiaomi / Mi Band import result surfaced in the Mi Band card.
    @Published var xiaomiImportSummary: String?
    /// Typed failure flags per source , the summary's warning styling reads these instead of
    /// substring-matching the human-readable message (which misses errors like "Couldn't open
    /// the local store."). Surfaced on both the Data Sources cards and the onboarding import step.
    @Published var whoopImportFailed = false
    @Published var appleHealthImportFailed = false
    @Published var xiaomiImportFailed = false
    /// A decoded Health Shortcut import waiting for explicit user confirmation before it writes rows.
    @Published var pendingShortcutHealthImport: ShortcutHealthImport.PendingImport?

    /// True while any data-source import is writing to the local store.
    var hasActiveImport: Bool { activeImportSource != nil }

    /// Returns true only for the source currently importing.
    func isImporting(_ source: DataSourceImportKind) -> Bool {
        activeImportSource == source
    }

    /// Whether the last import for a source ended in failure (for warning styling).
    func importFailed(_ source: DataSourceImportKind) -> Bool {
        switch source {
        case .whoop: return whoopImportFailed
        case .appleHealth: return appleHealthImportFailed
        case .xiaomi: return xiaomiImportFailed
        }
    }

    /// Smoothed, display-ready live heart rate , median over a short window, spike-filtered.
    /// Every screen should show THIS, not the raw per-beat value (which swings with HRV).
    @Published var bpm: Int?
    private var hrWindow: [(t: Date, v: Double)] = []
    private var hrCancellables = Set<AnyCancellable>()
    /// Drives the READ spine off the registry's active device (#814 HIGH-1). A Devices-screen
    /// switch/remove/re-add calls `registry.setActive` DIRECTLY (not through `registerDevice`), so without
    /// this subscription the reads stayed pinned to whatever id was active at wiring time for the whole
    /// session. Mirrors how `SourceCoordinator` drives the WRITE side off the same publisher. Retained for
    /// the app's lifetime (the registry outlives the session); `removeDuplicates` collapses redundant emits.
    private var readSpineCancellable: AnyCancellable?
    /// Daily re-arm timer for the single-instant firmware smart alarm (see scheduleDailySmartAlarmRearm).
    private var smartAlarmRearmTimer: Timer?

    init() {
        let live = LiveState()
        self.live = live
        // SEED every subsystem with the same id (`deviceId`, "my-whoop" at launch). The store/registry
        // aren't open yet here, so the registry's active id can't be read synchronously; `bootstrapStore`
        // (write side) and `wireSourceCoordinator → adoptActiveDevice` (read spine, #814) re-point them to
        // the registry active id once the store opens. Single-device install keeps "my-whoop" throughout.
        self.ble = BLEManager(state: live, deviceId: deviceId)
        self.repo = Repository(deviceId: deviceId)
        self.coach = AICoachEngine(repo: repo)
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: deviceId)
        // Route the engine's per-day scoring diagnostic into the SAME shareable strap log every other
        // subsystem writes to (PII-scrubbed by `live.append(log:)`), so a bug report ships proof of what
        // was computed per day. `live` is captured strongly (created just above) , the engine outlives the
        // app session, so there's no retain-cycle risk worth a weak dance here. (Sleep overhaul §2.5.)
        self.intelligence.diagnosticSink = { [live] line, domain in live.append(log: line, domain: domain) }
        // Workouts & GPS test mode (Test Centre): wire the Repository (auto-detect inputs/why + cross-source
        // dedup decisions) and the GPS recorder (fix-progress) tagged sinks to the SAME shareable strap log.
        // Each emitter re-checks `TestCentre.active(.workouts)` before building a line, so these wirings are
        // inert (one UserDefaults bool read) when the mode is off. `live` is captured strongly, as above.
        self.repo.workoutsLog = { [live] line in live.append(log: line, domain: .workouts) }
        self.gpsRecorder.workoutsLog = { [live] line in live.append(log: line, domain: .workouts) }
        // #961: give the read model the user's HRmax + sex so it can backfill a strap-native workout's
        // Effort on display when the stored value is nil (a live/manual session that ended with sparse HR).
        // Seed it now and keep it in step with any profile edit (objectWillChange fires just before a
        // @Published setter lands, so read the CURRENT values , they're already committed by the time the
        // next reconcile reads `strainProfile`). Display-only; the score itself is unchanged.
        self.repo.strainProfile = Repository.StrainProfile(hrMax: Double(profile.hrMax), sex: profile.sex)
        profile.objectWillChange.sink { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.repo.strainProfile = Repository.StrainProfile(
                    hrMax: Double(self.profile.hrMax), sex: self.profile.sex)
            }
        }.store(in: &hrCancellables)
        // Smooth HR centrally so it's solid everywhere it's shown.
        live.$heartRate.sink { [weak self] _ in self?.ingestHR() }.store(in: &hrCancellables)
        live.$rr.sink { [weak self] _ in self?.ingestHR() }.store(in: &hrCancellables)

        // Physical-input + wear hooks (fired live by FrameRouter).
        live.onDoubleTap = { [weak self] in self?.handleDoubleTap() }
        live.onWristChange = { [weak self] worn in self?.handleWristChange(worn) }
        // Re-arm the next day's firmware alarm the moment the strap reports it fired (if/when the
        // firmware pushes STRAP_DRIVEN_ALARM_EXECUTED). Gated on enabled inside applySmartAlarm.
        live.onSmartAlarmFired = { [weak self] in
            guard let self, self.behavior.smartAlarmEnabled else { return }
            // PR #577 (iOS): mirror the strap's wake buzz to a local notification so a phone-in-pocket
            // user still gets woken; no-op on macOS / when wrist alerts are off.
            AppModel.postSmartAlarm()
            self.applySmartAlarm()
        }
        // Strap battery alerts (#368): low-battery warning + full-charge note. The notifier self-gates
        // on the user's setting and the OS authorization, and carries its own persisted once-per-
        // crossing state, so feeding it every battery reading is safe.
        live.onBatteryUpdate = { [weak self] pct in
            guard let self else { return }
            BatteryNotifier.onBatteryUpdate(pct: Int(pct.rounded()),
                                            charging: self.live.charging,
                                            enabled: self.behavior.batteryAlerts)
            // Predictive runtime alert: the same reading just banked into the SoC buffer, so
            // batteryEstimate is fresh here. Nil estimate (no readings yet) is a no-op — the 15%
            // alert above remains the safety net.
            BatteryNotifier.onRuntimeEstimate(remainingHours: self.live.batteryEstimate?.remainingHours,
                                              charging: self.live.charging,
                                              enabled: self.behavior.batteryAlerts
                                                    && self.behavior.batteryPredictiveAlerts)
            // ESCALATION (both independent of the two latching gates above). The 15% alert and the
            // 24 h predictive alert each fire ONCE per discharge cycle and then latch, so a strap that
            // keeps draining goes silent exactly when the news gets worse — measured: a user got both
            // alerts, then nothing across the final ~3 h to the ~10% cutoff, and lost the night.
            //
            // 1. Critical SoC: a second, lower crossing with its own persisted gate.
            BatteryNotifier.onCriticalBattery(pct: Int(pct.rounded()),
                                              charging: self.live.charging,
                                              enabled: self.behavior.batteryAlerts)
            // 2. Bedtime night-guard: near the LEARNED habitual bedtime, does the strap actually clear
            //    tonight? Uses the cutoff-aware runtime (the raw estimate is time-to-0%, and the strap
            //    dies ~10% above that — ~6 h of phantom runway at this user's drain). Cold-start (no
            //    learned midsleep / too few nights) → the policy returns silent, no fabricated bedtime.
            //    Rides the predictive toggle: it IS a prediction.
            BatteryNotifier.onBedtimeRunway(
                nowSecOfDay: Self.localSecOfDayNow(),
                habitualMidsleepSec: self.habitualMidsleepCache,
                typicalSleepHours: BatteryEstimator.typicalSleepHours(
                    nightlyHours: self.repo.days.compactMap { $0.totalSleepMin.map { $0 / 60.0 } }),
                usableRemainingHours: self.live.batteryEstimate.map(BatteryEstimator.usableRemainingHours),
                charging: self.live.charging,
                enabled: self.behavior.batteryAlerts && self.behavior.batteryPredictiveAlerts)
        }
        // HR-zone haptic coaching watches the smoothed bpm.
        $bpm.sink { [weak self] hr in self?.coachZone(hr) }.store(in: &hrCancellables)
        // Illness/strain early-warning recomputes when the daily history changes.
        repo.$days.sink { [weak self] days in
            self?.evaluateIllness(days)
            self?.evaluateStrainTarget()
            // Keep the battery night-guard's learned bedtime warm off the same signal (throttled inside).
            self?.refreshHabitualMidsleep()
        }.store(in: &hrCancellables)
        // Re-arm the strap's firmware alarm once the connection has SETTLED — not the instant it (re)bonds.
        // A smart-alarm time changed while the strap was away never reached it , the send is gated on bond
        // , so the strap kept the OLD time and fired at it (#59).
        //
        // #34: keyed off `connectSettled` (a monotonic counter BLEManager bumps once the connect handshake
        // has both run AND the cmd-notify characteristic has confirmed subscribed — see LiveState.swift /
        // BLEManager.maybeSignalConnectSettled), NOT off raw `bonded`. `state.bonded` publishes from
        // INSIDE BLEManager's connect-handshake continuation (the bonding-confirm write's
        // didWriteValueFor), and Combine delivered to a `$bonded` sink SYNCHRONOUSLY on that same call
        // stack — arming there nested the alarm's SET_CLOCK/SET_ALARM_TIME/GET_ALARM_TIME burst in the
        // MIDDLE of the handshake, ahead of its own clock-set and before the cmd-notify channel was
        // confirmed subscribed. A strap log (#34 v8.6.2) confirmed the result: the alarm's GET_ALARM_TIME
        // readback got no reply at all — the strap's answer had nowhere confirmed-subscribed to land.
        // `connectSettled` only bumps once that channel is confirmed live, so the readback (and the arm
        // itself) always goes out on a link that's actually ready. `dropFirst()` skips the initial
        // published value (0) at subscribe time, so this doesn't fire on app launch before any connection.
        // #730: ALSO re-run when a DISARM was dropped. `applySmartAlarm()` branches internally (enabled →
        // arm, disabled → disarm), but gating purely on `smartAlarmEnabled` meant a user who turned the
        // alarm OFF while disconnected had the disarm swallowed by `send` and never retried — the strap
        // kept the old firmware alarm and still buzzed, while the app logged "Alarm: disarmed".
        // `disarmPending` latches exactly that dropped write, so this stays a no-op for the many users who
        // never armed one (re-running unconditionally would put a DISABLE_ALARM on every connect).
        live.$connectSettled.dropFirst().sink { [weak self] _ in
            guard let self, self.behavior.smartAlarmEnabled || self.ble.disarmPending else { return }
            self.applySmartAlarm()
        }.store(in: &hrCancellables)
        // The firmware alarm is a single absolute instant with no recurrence, and was re-armed ONLY on
        // a (re)bond or a settings change. A strap that stays continuously bonded (a Mac in range) would
        // fire once and never re-arm , silent from day two. Re-arm daily so an always-on session keeps
        // waking the user.
        scheduleDailySmartAlarmRearm()
        // Re-apply "Continuous HRV capture" on every (re)bond: if on, the strap should hold the dense
        // realtime stream armed even with no Live screen open, so it banks beat-to-beat R-R 24/7 for
        // better overnight HRV/recovery/sleep. The BLE reconciler arms it on the off→on edge; pushing it
        // here (and at the init tail) covers a fresh launch and every reconnect. (See PuffinExperiment.)
        live.$bonded.removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            self.ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
            self.applyPowerSaving()
        }.store(in: &hrCancellables)
        // A completed backfill has just written strap history. Refresh the dashboard cache,
        // but leave heavyweight analysis to its own guarded/background-friendly path.
        //
        // #755 COALESCE: a strap whose firmware segments a deep offload into many small HISTORY_COMPLETE
        // slices stamps `lastSyncedAt` once PER slice (BLEManager.exitBackfilling), seconds apart, for the
        // whole multi-minute download. Without coalescing each slice fired refreshAfterCompletedBackfill()
        // , a full repo.refresh (~50 store reads) + analyzeRecent , and every one re-fired TodayView's
        // ~50-read loadAll, all contending with the backfill's bulk writes on the single-connection store.
        // On a heavy + actively-syncing history that stacked into a ~10s freeze. `.debounce` collapses the
        // slice storm: it suppresses the intermediate emissions and fires ONCE, 2s after the stream goes
        // quiet , i.e. after the LAST slice lands (the backfill is done). Crucially it ALWAYS delivers the
        // trailing edge, so the dashboard still refreshes with the newly-synced data , freshness is kept,
        // we just stop re-doing it dozens of times mid-download. removeDuplicates() still drops a slice that
        // stamped an identical second; the trailing refresh after a real change is never dropped.
        live.$lastSyncedAt
            .dropFirst()
            .compactMap { $0 }
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshAfterCompletedBackfill() }
            }
            .store(in: &hrCancellables)

        moments = (UserDefaults.standard.array(forKey: "moments") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
        sleepMarks = (UserDefaults.standard.array(forKey: "sleepMarks") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
        // Rehydrate a manual workout that was in flight when iOS killed the app, so it can still be ended
        // + saved on relaunch (#529). Restored here alongside the other UserDefaults-backed state.
        rehydrateActiveWorkout()

        AppModel.shared = self   // publish for App Intents (Shortcuts) , see the static above (#42)

        // Seed the BLE client with the persisted "Continuous HRV capture" intent so `wantsRealtime`
        // reflects it from launch , the reconciler then arms the dense stream as soon as the strap bonds
        // (and the bond sink above re-applies it on every reconnect).
        ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
        applyPowerSaving()

        // Turn the strap's offloaded raw data into dashboard scores on launch and every 15
        // minutes, so recovery / strain / sleep populate from the strap itself with no import.
        // IntelligenceEngine computes, persists under "my-whoop-noop", and refreshes the dashboard.
        // One-shot reclaim of any stale Documents/Inbox picker drops a previous build left behind
        // before cleanup() reclaimed the original, PLUS any stranded `noop-*` temp scratch (e.g. the
        // multi-GB `noop-health-*` export.xml an interrupted import leaves behind , #590). Off the main
        // actor; no-op on macOS for the Inbox part.
        Task.detached { AppModel.purgeImportInbox(); AppModel.purgeImportTemp() }

        // FIX 2(b): the launch sequence runs at `.utility` so its heavy one-shot 4000-day heal/rescore
        // yields to UI rendering instead of contending at the inherited user-initiated QoS. The reads are
        // already off the main actor (analyzeRecent , FIX 1), and at `.utility` the scheduler keeps the
        // main thread free for SwiftUI during the deep-history pass right after an import / first launch.
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            #if DEBUG
            // DEBUG-only: when launched with `--demo-seed`, populate a deterministic synthetic
            // dataset so an empty simulator/dev build can walk every screen (verification + marketing
            // screenshots). No-op in Release (whole seeder is #if DEBUG) and once data already exists.
            if AppleDemoSeeder.requested, let store = await self.repo.storeHandle() {
                await AppleDemoSeeder.seedIfRequested(into: store)
                // Give the demo a plausible strap battery so the Today header badge renders (the live
                // battery is runtime-only and nil without a connected strap).
                self.live.batteryPct = 68
            }
            #endif
            await self.repo.refresh()                          // surface any imported data at once
            await self.wireSourceCoordinator()                 // dormant unless a generic strap is active
            try? await Task.sleep(nanoseconds: 6_000_000_000)  // give the first offload a moment
            // FIX 2(a): DEFER the heavy one-shot 4000-day heal/rescore while an import is in flight. A
            // large Apple Health import is the worst-case launch overlap , running a 4000-iteration heal
            // + rescore concurrently with the import's parse+writes is what produced the ~1-minute app-wide
            // lag. The import refreshes the dashboard itself on completion, and the steady-state cadence
            // loop below still runs, so deferring the ONE-SHOT passes until the import finishes costs
            // nothing but removes the contention. Bounded poll (respects cancellation); typical imports
            // clear in seconds, so this almost always passes through immediately.
            // CAP the wait (#review): `hasActiveImport` is cleared only by finishImport(), which a true
            // non-throwing import HANG would never reach, permanently starving the one-shot passes AND the
            // cadence loop below for the whole session. Bound it so a wedged import can't disable analysis;
            // the merge reads are off-actor now, so proceeding under a still-flagged import is safe.
            var importWaited = 0
            while self.hasActiveImport && !Task.isCancelled && importWaited < 180 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 s, re-check; ~3 min cap then proceed
                importWaited += 1
            }
            // One-shot on-upgrade heal (#547): purge rows a bad-clock strap dated to scattered garbage
            // (far-past / bogus-2027 / FUTURE) from an older build, then rescore the real days. Runs
            // BEFORE the Effort rescore + analyzeRecent loop so both operate on a cleaned DB. Persisted
            // flag → no-op on every subsequent launch; idempotent on a clean DB.
            await self.intelligence.runTimestampHealIfNeeded()
            // One-shot on-upgrade Effort rescore (#313): recompute strain from source across the FULL
            // history once, so any deep-history rows an older build left on the 0–21 axis regenerate on
            // the 0–100 axis. Guarded by a persisted flag, so this is a no-op on every subsequent launch.
            await self.intelligence.runEffortRescoreIfNeeded()
            while !Task.isCancelled {
                // #547 RE-POLLUTION: a sync since the last tick may have armed a re-heal (its ingest gate
                // dropped bad-clock records). `runTimestampHealIfNeeded` honours the pending flag even after
                // the one-shot done flag is set, purges any pollution, and rescores the affected days , so a
                // wandering-clock strap can't keep re-polluting. A no-op when nothing's pending.
                await self.intelligence.runTimestampHealIfNeeded()
                // #836: the steady-state tick is a BACKSTOP, not a data-driven refresh — every real update
                // (sync backfill, import, edit, recalibrate, heal) already rescores via its own forced call.
                // `force: false` skips the heavy 21-day rescore when the raw HR stream is unchanged since the
                // last run, instead of re-reading ~21×54 h of HR every 15 min on a big-import library. A new
                // sample (the heal above, or a sync) moves the fingerprint and the tick rescores as before.
                await self.intelligence.analyzeRecent(force: false)
                // v5: recompute the skin-temp suite snapshots (cycle phase + body clock) from the
                // freshly-scored history so the Health hub cards read a ready result.
                await self.refreshV5Signals()
                // #836 battery: 30-min BACKSTOP cadence (twin of Android ANALYZE_INTERVAL_MS). The
                // `force: false` gate above can't skip while the strap streams live HR — the fingerprint
                // advances every second — so this re-scored the whole 21-day window every 15 min even though
                // only today's daytime HR changed. It's a pure backstop (every real update rescores via its
                // own forced call above), so halving the cadence only delays the idle refresh of today's
                // live Effort/steps; recovery/sleep are night-computed and unaffected.
                try? await Task.sleep(nanoseconds: 1_800_000_000_000)  // 30 min backstop (#836 battery)
            }
        }
    }

    /// Build the device registry + source coordinator once the store is open, then start observing.
    /// #477: push the persisted Power-saving prefs to the BLE manager (parity with Android
    /// `AppViewModel.applyPowerSaving`). Offload-cadence stretch uses the battery-% threshold (0 = off
    /// when the master is off); the HRV pause is a sub-option, only effective while the master is on.
    /// The riskier connection-priority idle throttle is intentionally not wired (Android-only, and dormant).
    func applyPowerSaving() {
        let on = PuffinExperiment.powerSavingEnabled
        ble.setLowBatteryOffloadThrottle(on ? PuffinExperiment.powerSavingBatteryPct : 0)
        // HRV pause is battery-%-aware like the offload lever — pass the same threshold.
        ble.setPauseCaptureOnPowerSave(on && PuffinExperiment.pauseHrvOnPowerSaveEnabled,
                                       thresholdPct: PuffinExperiment.powerSavingBatteryPct)
    }

    /// Tiny and guarded: with no generic strap paired the active id is "my-whoop", so the coordinator
    /// observes WHOOP-active and stays a NO-OP , the existing `scan()`/`disconnect()` WHOOP flow is
    /// untouched. The coordinator only acts if/when a non-WHOOP strap becomes the active device.
    /// `startWhoop`/`stopWhoop` are thin closures over BLEManager's EXISTING public methods (via the
    /// model's `scan()` / `disconnect()`), so the coordinator never references BLEManager directly.
    private func wireSourceCoordinator() async {
        guard sourceCoordinator == nil, let store = await repo.storeHandle() else { return }
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryWriter))
        registry.reload()
        let coordinator = SourceCoordinator(
            registry: registry,
            live: live,
            storeHandle: { [weak self] in await self?.repo.storeHandle() },
            startWhoop: { [weak self] in self?.scan() },
            stopWhoop: { [weak self] in self?.disconnect() },
            // WHOOP targeting hooks , thin wrappers over BLEManager's existing additive setters, so the
            // coordinator never references BLEManager directly (mirrors the start/stop injection). On the
            // single-WHOOP path these are setPreferredPeripheral(nil) and (no setActiveDeviceId call),
            // i.e. the BLE engine's defaults , no behaviour change.
            setWhoopPreferredPeripheral: { [weak self] uuid in self?.ble.setPreferredPeripheral(uuid) },
            setWhoopActiveDeviceId: { [weak self] id in self?.ble.setActiveDeviceId(id) },
            // The engine's last-connected WHOOP uuid drives first-connect identity adoption.
            connectedPeripheralUUID: ble.$connectedPeripheralUUID.eraseToAnyPublisher(),
            // Generic-HR connect lifecycle → the SAME strap log BLEManager writes to (`live.append(log:)`),
            // so a "connected but no data" report (issue #421) is no longer blind to the Polar/Wahoo/etc
            // path. Timestamp matches BLEManager.log()'s "HH:mm:ss" so the lines read consistently.
            straplog: { [weak self] line in
                self?.live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] \(line)")
            })
        coordinator.start()
        self.deviceRegistry = registry
        self.sourceCoordinator = coordinator
        // #814 READ SPINE (HIGH-1): drive the read side off the registry's `activeDeviceId` for the WHOLE
        // session, exactly as SourceCoordinator drives the WRITE side off the SAME publisher. A Devices-
        // screen switch/remove/re-add calls `registry.setActive` DIRECTLY (NOT through `registerDevice`), so
        // a one-shot adopt at wiring time would leave the reads pinned to the launch-time active id all
        // session, a re-add's fresh "whoop-<uuid>" raw never surfaced until the next relaunch. The
        // subscription re-points the Repository's active-strap READ id on every change; `adoptActiveDevice`
        // is idempotent, so the initial emission (the current active id) does the first adopt and any later
        // explicit `adoptActiveDevice` call (e.g. from `registerDevice`) is safely redundant. The import +
        // computed WRITE targets stay STABLE on the canonical id (see `adoptActiveDevice`'s union-model note).
        readSpineCancellable = registry.$activeDeviceId
            .removeDuplicates()
            .sink { [weak self] id in
                Task { await self?.adoptActiveDevice(id) }
            }
    }

    /// Re-point the Repository's ACTIVE-strap READ id at `activeId` and, if it moved, refresh + re-score so a
    /// re-added strap's LIVE raw (written under its fresh "whoop-<uuid>" id) surfaces on the dashboard (#814).
    /// Centralised so the registry-active subscription and a device add/activate share one path. A no-op (no
    /// refresh) when the id is unchanged (the common single-device case).
    ///
    /// UNION MODEL (#814 follow-up): this moves ONLY the read-side active-strap id. The WHOOP-IMPORT + the
    /// engine's COMPUTED write target, and the FusionSource `.whoopImport` mapping, stay STABLE on the
    /// canonical `deviceId` ("my-whoop"), they must NOT follow the active strap, or history imported/scored
    /// earlier under the canonical id would be orphaned. The Repository reads the UNION of the active strap +
    /// the canonical id, so both the re-added strap's live data AND the canonical history surface. The engine
    /// already resolves the active strap per day via the registry's own active id (`resolveDayOwner`), so it
    /// reads + scores the re-added strap's raw and writes the computed result to the STABLE canonical
    /// `-noop` sibling, no engine re-point needed.
    private func adoptActiveDevice(_ activeId: String) async {
        let trimmed = activeId.trimmingCharacters(in: .whitespaces)
        let repoMoved = repo.adoptActiveDeviceId(trimmed)
        guard repoMoved else { return }
        live.append(log: "Read spine re-pointed to active device after registry change (#814).")
        await repo.refresh()
        await intelligence.analyzeRecent()
    }

    #if os(iOS)
    /// Push freshly-offloaded data to Apple Health, set by `StrandiOSApp` (#1021).
    ///
    /// A closure rather than a direct reference because `HealthKitBridge` owns iOS-only HealthKit state
    /// while this type is shared with macOS, and the bridge is a `@StateObject` the app scene owns.
    var healthWriteBack: (() async -> Void)?
    #endif

    private func refreshAfterCompletedBackfill() async {
        live.append(log: "Backfill: refreshing dashboard cache from completed sync")
        await repo.refresh(days: 120)
        // Score the freshly-offloaded raw data RIGHT NOW rather than waiting for the next 15-minute
        // analyzeRecent tick , otherwise a just-synced night's Charge / Effort / Rest can take up to
        // 15 minutes to appear on a strap-only (no-import) dashboard. analyzeRecent no-ops if a tick is
        // already running and refreshes the dashboard itself once the new scores persist. (PR #218)
        // #1196/#1146: `skipIfUnchanged` gates THIS post-offload pass on the HR fingerprint — an empty/
        // duplicate offload (nothing new banked, common on a flapping link) skips the whole-window rescore
        // instead of churning it, which was surfacing as a Trends/streak "0 days" flicker. Only this
        // post-offload caller opts in; every other analyzeRecent path still forces unconditionally.
        await intelligence.analyzeRecent(skipIfUnchanged: true)
        await refreshV5Signals()
        #if os(iOS)
        // #980: a strap backfill routinely completes while the app is BACKGROUNDED (it runs as a
        // bluetooth-central, so it stays alive to receive the offload). The only other widget-publish
        // sites are gated on scenePhase == .active, so a background sync would rescore today's data but
        // never rewrite the shared App-Group snapshot or call WidgetCenter.reloadAllTimelines — the
        // widget kept showing yesterday's numbers. Publishing here, on the real "new data landed"
        // signal, pushes the fresh snapshot to the home-screen widget without needing a foreground.
        await WidgetSnapshot.publish(from: self)
        // #1021: same reasoning as the widget publish above, for Apple Health. The only automatic
        // write-back ran on scenePhase == .active, in the same block that KICKS this offload - so it
        // raced the data it was meant to publish and last night's sleep reached Health an app-open late.
        // Set by StrandiOSApp; nil on macOS and in tests, where there is no bridge.
        await healthWriteBack?()
        #endif
    }

    /// Fold a fresh reading into the smoothing window and republish a stable bpm.
    /// Prefers the strap's reported HR; falls back to 60000/R-R. Clamps to a plausible
    /// 30–220 range (rejects 0 / garbage spikes) and publishes the window MEDIAN.
    private func ingestHR() {
        var inst: Double?
        if let hr = live.heartRate, hr >= 30, hr <= 220 {
            inst = Double(hr)
        } else if let rr = live.rr.last, rr > 0 {
            let v = 60_000.0 / Double(rr)
            if v >= 30, v <= 220 { inst = v }
        }
        guard let inst else {
            // #39: when the live source is gone (disconnect blanks heartRate AND rr), drop the stale
            // median so screens that now prefer `bpm` fall through to "," instead of freezing on the
            // last value. Mirrors Android (_bpm = null on disconnect). A transient out-of-range sample
            // with the link still up (heartRate or rr still present) keeps the last median.
            if live.heartRate == nil && live.rr.isEmpty { resetSmoothing() }
            return
        }
        let now = Date()
        hrWindow.append((now, inst))
        hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10s window
        if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
        let vals = hrWindow.map(\.v).sorted()
        // live perf: only republish when the SMOOTHED value actually changes. ingestHR fires on every
        // heartRate AND rr update (~1–3 Hz), but the median is stable across most of them , an
        // unconditional assign re-renders every bpm observer (Live, menu bar, widgets) for nothing.
        let smoothed = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
        if bpm != smoothed { bpm = smoothed }
        captureWorkoutSample()
        evaluateStress()
    }

    // MARK: - Manual workout tracking

    /// Begin a manually-tracked workout for the named `sport` (the picker passes the chosen catalogue
    /// name; callers that don't pick a sport get the catalogue default "Other", parity with Android's
    /// `startWorkout(sport:)`). The active card on Live then shows elapsed time, live HR and strain
    /// building; End scores + saves it under this sport. Confirms with a single buzz. (#519)
    func startWorkout(sport: String = WorkoutCatalog.defaultSportName) {
        guard activeWorkout == nil else { return }
        lastWorkout = nil
        let name = sport.trimmingCharacters(in: .whitespaces)
        let resolved = name.isEmpty ? WorkoutCatalog.defaultSportName : name
        let started = Date()
        activeWorkout = ActiveWorkout(start: started, sport: resolved)
        // #524: arm GPS route recording for a distance-type sport (run / ride / walk / hike), mirroring
        // Android, which defaults GPS on for `isDistanceSport`. Manual-first / opt-in: only these sports
        // record a route, and the recorder still captures nothing unless the user grants When-In-Use
        // location (and on a Mac with no GPS it stays empty) , the session always banks HR + Effort
        // regardless. A non-distance sport (yoga, strength) never touches location at all.
        activeWorkoutIsGps = WorkoutCatalog.sport(named: resolved)?.isDistanceSport ?? false
        if activeWorkoutIsGps {
            gpsRecorder.start(startMs: Int64(started.timeIntervalSince1970 * 1000))
        }
        // Make the session durable from the first instant (#529): persist it now so an OS kill right
        // after Start , before any HR sample lands , can still be rehydrated + ended on relaunch.
        persistActiveWorkout()
        // Workouts & GPS test mode (Test Centre): one session-start line tagged `.workouts`. Zero-cost when
        // off (the gate is one UserDefaults bool read), so the lifecycle of a missing workout is visible.
        emitWorkoutsTrace(WorkoutsTrace.sessionLine(
            event: "start", sportKey: WorkoutSource.traceSportKey(resolved), hrSamples: 0))
        buzz(loops: 1, gate: HapticPrefs.workout)
    }

    /// Emit one Workouts & GPS test-mode line tagged `.workouts` iff the mode is on. The cheap
    /// `TestCentre.active(.workouts)` gate is checked BEFORE the @autoclosure builds the line, so nothing is
    /// constructed when the mode is off. Diagnostic only - the session lifecycle is unchanged.
    private func emitWorkoutsTrace(_ build: @autoclosure () -> String) {
        guard TestCentre.active(.workouts) else { return }
        live.append(log: build(), domain: .workouts)
    }

    /// The gated sink the import handlers pass to the importers for the Import & Data Ingest test mode.
    /// Returns nil when the mode is off, so the importer takes its byte-identical untraced path (it builds
    /// no trace line and captures nothing extra); returns a `@Sendable` closure that hops the batch of
    /// already-redacted lines to the main actor (LiveState is @MainActor) and appends them, tagged
    /// `.dataImport`, in order, when the mode is on. The importer runs nonisolated, so the main-actor hop
    /// keeps the append race-free. One UserDefaults bool read decides whether any of this runs.
    private func importTraceSink() -> (@Sendable ([String]) -> Void)? {
        guard TestCentre.active(.dataImport) else { return nil }
        return { [weak self] lines in
            Task { @MainActor in
                guard let self else { return }
                for line in lines { self.live.append(log: line, domain: .dataImport) }
            }
        }
    }

    /// Emit the file-meta line for an import run (detected kind + extension + size BUCKET, never the path or
    /// name), tagged `.dataImport`, iff the mode is on. Called by the handlers that have the materialized
    /// URL. The size is bucketed inside `ImportTrace`, so no byte-exact size or filename leaves the device.
    private func emitImportFileMeta(kind: DataSourceKind, url: URL) {
        guard TestCentre.active(.dataImport) else { return }
        let ext = url.pathExtension
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        live.append(log: ImportTrace.fileMetaLine(sourceKind: kind, ext: ext, sizeBytes: size),
                    domain: .dataImport)
    }

    /// Persist the in-flight manual workout to `UserDefaults` so it survives the app being killed mid-
    /// session (#529). Called on start + each captured sample. A no-op when nothing is running. Apple has
    /// no GPS-route session, so every manual workout is the "non-GPS" case and gets this durability ,
    /// the Apple analogue of Android's `persistNonGpsWorkout`.
    private func persistActiveWorkout() {
        guard let w = activeWorkout else { return }
        ActiveWorkoutPersistence.store(
            ActiveWorkoutPersistence.Snapshot(
                startSec: Int(w.start.timeIntervalSince1970),
                sport: w.sport,
                samples: w.samples,
                avgHr: w.avgHr,
                peakHr: w.peakHr,
                liveStrain: w.liveStrain))
    }

    /// If a manual workout was in flight when iOS killed the app, rebuild `activeWorkout` from the durable
    /// snapshot so reopening doesn't lose it , the session can still be ended + saved (#529). The Apple
    /// analogue of Android's `rehydrateActiveNonGpsWorkout`. No-op when a workout is already live (a live
    /// session wins over a stale snapshot) or nothing is stored. Called once from `init`.
    private func rehydrateActiveWorkout() {
        guard activeWorkout == nil, let snap = ActiveWorkoutPersistence.load() else { return }
        var w = ActiveWorkout(start: Date(timeIntervalSince1970: TimeInterval(snap.startSec)),
                              sport: snap.sport)
        w.samples = snap.samples
        w.avgHr = snap.avgHr
        w.peakHr = snap.peakHr
        w.liveStrain = snap.liveStrain
        activeWorkout = w
    }

    /// Finish the active workout: finalize the GPS route (#524), score the captured HR window, and save it
    /// as a `WorkoutRow`. A session with no HR window AND no real GPS route is discarded quietly (parity
    /// with Android) , but a GPS-only walk with HR not streaming still saves. Double-buzz confirms.
    func endWorkout() {
        guard let w = activeWorkout else { return }
        activeWorkout = nil
        let wasGps = activeWorkoutIsGps
        activeWorkoutIsGps = false
        // Drop the durable snapshot the instant the session ends , whether it saves below or is discarded
        // as too-short , so a relaunch never rehydrates an already-finished session (#529).
        ActiveWorkoutPersistence.clear()
        // #524: finalize the GPS route. Stop the recorder and take its captured route , it kept
        // accumulating from CoreLocation independently of the HR window. `capturedRoute()` is nil unless
        // ≥2 points actually landed (honest: no route, no distance, when nothing was captured , e.g. a
        // Mac with no GPS, or denied permission). A non-GPS session never armed the recorder.
        var route: WorkoutRoute?
        if wasGps {
            gpsRecorder.stop()
            route = gpsRecorder.capturedRoute()
        }
        let samples = w.samples
        // Save when there's an HR window OR a real GPS route , a GPS-only walk (HR not streaming) is
        // still a workout (parity with Android's `samples.size < 2 && track.size < 2` discard gate).
        guard samples.count >= 2 || route != nil else {
            // Workouts & GPS test mode: record WHY a session vanished (too short / no route), tagged `.workouts`.
            emitWorkoutsTrace(WorkoutsTrace.sessionLine(
                event: "discarded", sportKey: WorkoutSource.traceSportKey(w.sport),
                hrSamples: samples.count, gpsPoints: route == nil ? 0 : nil))
            lastWorkout = nil
            return
        }
        let end = Date()
        let avg = samples.isEmpty ? nil
            : Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
        let peak = samples.map(\.bpm).max()
        // #983: score the SAVED workout with the wearer's measured resting HR, not the hardcoded
        // default of 60. %HRR is (bpm - resting) / (max - resting), so the default moves every zone
        // boundary — at 136 bpm with maxHR 190 it is the difference between zone 1 and zone 2. Today's
        // Effort and the manual rescore (#972) already thread this, so the stored number used to
        // disagree with its own re-score. Read once here, at save time; the live readout during the
        // session is a transient running estimate and deliberately left alone.
        let restingHR = repo.today?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let strain = samples.count >= 2
            ? StrainScorer.strain(samples, maxHR: Double(profile.hrMax),
                                  restingHR: restingHR, sex: profile.sex) : nil
        // Estimate calories from the captured HR window (same Keytel/Harris–Benedict model the
        // auto-detector uses) so a manual session shows energy too, not just duration/strain. (#117)
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let kcal = samples.count >= 2
            // #983: same measured resting HR as the strain above, not nil. The calories model's
            // active-vs-resting threshold sits at resting + 30% HRR, so the default silently shifts what
            // counts as active — and #972 already threads it in the rescore path, so leaving it nil here
            // meant a saved workout's kcal disagreed with its own re-score just as its Effort did.
            ? Calories.estimateBoutCalories(samples, profile: up, hrmax: Double(profile.hrMax),
                                            restingHR: restingHR).0
            : 0
        let startTs = Int(w.start.timeIntervalSince1970)
        let row = WorkoutRow(
            startTs: startTs, endTs: Int(end.timeIntervalSince1970),
            sport: w.sport, source: "manual", durationS: end.timeIntervalSince(w.start),
            energyKcal: kcal > 0 ? kcal : nil, avgHr: avg, maxHr: peak, strain: strain,
            // GPS distance rides the shared row so the Workouts list / detail show it like any other
            // distance workout; the polyline itself is persisted alongside in RouteStore (the shared
            // WorkoutRow has no route column on Apple). Only a real route sets distance , honest ",".
            distanceM: route?.distanceM, zonesJSON: nil, notes: nil)
        // Persist the route polyline under the row's natural key so WorkoutDetailView can draw it. On
        // device only; mirrors the moments / sleepMarks UserDefaults persistence. (#524)
        if let route { RouteStore.store(route, startTs: startTs, sport: w.sport) }
        lastWorkout = row
        // Workouts & GPS test mode: one session-end summary tagged `.workouts` (the lastSessionSummary readout
        // source) carrying the captured HR window size, the duration, and the accepted GPS point count, so the
        // lifecycle of a saved session is visible end to end. `pointCount` is the recorder's accepted-fix tally
        // (not reset by stop), 0 for a non-GPS session. Zero-cost when off.
        emitWorkoutsTrace(WorkoutsTrace.sessionLine(
            event: "end", sportKey: WorkoutSource.traceSportKey(w.sport), hrSamples: samples.count,
            durationSec: Int(end.timeIntervalSince(w.start)),
            gpsPoints: wasGps ? gpsRecorder.pointCount : nil))
        buzz(loops: 2, gate: HapticPrefs.workout)
        Task { [weak self] in
            guard let self else { return }
            if let store = await self.repo.storeHandle() {
                _ = try? await store.upsertWorkouts([row], deviceId: self.deviceId)
                await self.repo.refresh()
            }
        }
    }

    /// Append the current smoothed `bpm` to the active workout and recompute its running strain. Called
    /// from `ingestHR` on every fresh sample; a no-op when no workout is running. Recomputing strain
    /// over the growing window each sample is cheap at the ~1 Hz live-HR cadence.
    private func captureWorkoutSample() {
        guard var w = activeWorkout, let hr = bpm else { return }
        w.samples.append(HRSample(ts: Int(Date().timeIntervalSince1970), bpm: hr))
        w.peakHr = max(w.peakHr, hr)
        w.avgHr = Int((Double(w.samples.map(\.bpm).reduce(0, +)) / Double(w.samples.count)).rounded())
        w.liveStrain = StrainScorer.strain(w.samples, maxHR: Double(profile.hrMax), sex: profile.sex) ?? 0
        activeWorkout = w
        // Re-snapshot the durable session so a kill keeps the latest accumulated HR window (#529).
        persistActiveWorkout()
    }

    /// Drop the smoothing window and blank the hero number so a resume / re-attach shows ","
    /// until a genuinely fresh sample arrives, instead of republishing the stale pre-gap median.
    /// Called on Live-tab entry / manual Start HR (see `startRealtimeHR`), NOT on the 30s keep-alive
    /// re-arm , so steady-state smoothing is untouched. Fixes #46 (HR jumped to a stale ~100 on
    /// reopen, then "slowly came back down" as fresh low samples refilled the window).
    func resetSmoothing() {
        hrWindow.removeAll()
        bpm = nil
    }

    /// The unit-tested `StressOnsetDetector` decides whether to offer a 60-s guided breath. On a fresh,
    /// non-metabolic HRV dip while the user is still, it fires a single confirming buzz and posts a
    /// passive nudge to `stressNudgeCenter`. The detector carries replay-safe state (de-dup + slow
    /// baseline + rate limit), persisted via `BiofeedbackPrefs` so a relaunch can't re-fire. Honest /
    /// non-clinical: "stress" is an autonomic proxy vs the user's own baseline, never a diagnosis.
    private func evaluateStress() {
        let fresh = live.rr.filter { $0 > 300 && $0 < 2000 }   // plausible R-R (30–200 bpm)
        guard !fresh.isEmpty else { return }
        rrBuf.append(contentsOf: fresh)
        if rrBuf.count > 120 { rrBuf.removeFirst(rrBuf.count - 120) }

        // Inert unless the master toggle is on; the engine owns every gate (auto-nudge, exercise gate,
        // quiet hours, rate limit, edge).
        let cfg = BiofeedbackPrefs.stressConfig()
        guard cfg.enabled, live.bonded, live.worn else { return }
        let decision = StressOnsetDetector.evaluate(
            rrBuffer: rrBuf,
            currentHR: bpm.map(Double.init),
            recentMotionG: nil,   // wrist gravity is offloaded + lags live; the resting-HR band is the gate
            sessionActive: stressNudgeCenter.pending != nil,   // never stack a fresh nudge over a live one
            state: stressState,
            config: cfg,
            nowSec: Int(Date().timeIntervalSince1970),
            tzOffsetSec: TimeZone.current.secondsFromGMT())
        stressState = decision.nextState
        BiofeedbackPrefs.saveStressState(decision.nextState)
        guard decision.shouldNudge else { return }
        if canBuzz { buzz(loops: UInt8(clamping: decision.buzzLoops)) }
        stressNudgeCenter.present(fastRMSSD: decision.fastRMSSD, baselineRMSSD: decision.baselineRMSSD)
        live.append(log: "Stress check-in , HRV dipped while still")
    }

    /// Whether the encrypted channel is up so a confirming buzz can actually fire (the command
    /// characteristic is gated on bond; an un-encrypted live-HR-only link can't buzz).
    private var canBuzz: Bool { live.bonded && live.encryptedBond }

    /// Start scanning for the strap. When no model is given, use the one the user
    /// picked (persisted under "selectedWhoopModel"), so every scan entry point ,
    /// Live, onboarding, the menu bar, Settings , honours the same choice.
    func scan(model: WhoopModel? = nil) {
        let chosen = model
            ?? UserDefaults.standard.string(forKey: "selectedWhoopModel").flatMap(WhoopModel.init(rawValue:))
            ?? .whoop4
        ble.connect(model: chosen)
    }
    func disconnect() { ble.disconnect() }
    /// Restart the connected strap (user-initiated, confirmation-gated in DevicesView). Non-destructive —
    /// the strap keeps its data and re-advertises after boot; NOOP auto-reconnects. See BLEManager.rebootStrap().
    func rebootStrap() { ble.rebootStrap() }
    /// Send one WHOOP 4.0 reboot-probe candidate (Test Centre → Connection, 4.0 only). Confirmation-gated
    /// in DevicesView; finds the real 4.0 reboot frame when the production one is ignored (#235).
    func rebootProbe(_ variant: RebootProbeVariant) { ble.rebootProbe(variant) }

    /// #592 read-only extended-battery opcode probe (Devices → strap menu, Test Centre → Connection gated).
    func probeExtendedBatteryInfo() { ble.probeExtendedBatteryInfo() }
    func clearExtendedBatteryProbe() { ble.clearExtendedBatteryProbe() }

    // #690: read-only body-location/status probe (0x54). User-initiated, Test-Centre-gated in DevicesView.
    func probeBodyLocationAndStatus() { ble.probeBodyLocationAndStatus() }
    func clearBodyLocationProbe() { ble.clearBodyLocationProbe() }

    // #761: READ-ONLY feature-flag ENUMERATION probe (117/118) — reads the flag NAMES the strap's firmware
    // knows and writes nothing. User-initiated, Test-Centre-gated in DevicesView.
    func probeFeatureFlags() { ble.probeFeatureFlags() }
    func clearFeatureFlagProbe() { ble.clearFeatureFlagProbe() }

    // WHOOP MG ECG ("Labrador") experimental probe. Every entry point is user-initiated and
    // confirmation-gated in DevicesView, and BLEManager gates the sends again on the Experimental opt-in
    // plus a positively-identified MG. Unvalidated instrumentation, never a medical measurement.
    /// True only for a POSITIVELY identified WHOOP MG — the gate the ECG UI is offered behind.
    var isWhoop5MG: Bool { ble.isWhoop5MG }
    /// PERSISTENT strap write, deliberately its own action rather than part of the start flow.
    func ecgSelectWrist(_ wrist: Whoop5Ecg.WristSelection) { ble.ecgSelectWrist(wrist) }
    func ecgStartCapture() { ble.ecgStartCapture() }
    /// `reportsResult: false` for the Settings-toggle path, so switching the experiment off doesn't pop
    /// the Devices result sheet from another screen.
    func ecgStopCapture(reportsResult: Bool = true) { ble.ecgStopCapture(reportsResult: reportsResult) }
    func clearEcgProbe() { ble.clearEcgProbe() }
    /// True once a start has been sent this session and no stop has completed — keeps the Stop control
    /// reachable even after the opt-in has been switched back off.
    var ecgMayBeRunning: Bool { ble.ecgMayBeRunning }
    // #103: READ-ONLY device-config READ probe (121/128) — asks the strap for a key's VALUE, the
    // follow-up to #761's key-NAME enumeration. Writes nothing. User-initiated, Test-Centre-gated in
    // DevicesView.
    func probeDeviceConfigValues() { ble.probeDeviceConfigValues() }
    func clearDeviceConfigProbe() { ble.clearDeviceConfigProbe() }

    /// Drop the current strap and clear bond state so a newly-picked strap model connects fresh
    /// (lets a user with both a WHOOP 4 and a 5/MG switch between them).
    func prepareStrapSwitch() { ble.prepareForModelSwitch() }

    // MARK: - Add-a-device wizard (WHOOP present-scan + register/activate)
    //
    // Thin pass-throughs over BLEManager's EXISTING public present-scan surface so the wizard never
    // references BLEManager directly (mirrors `scan()` / `disconnect()`). The wizard observes
    // `ble.discoveredWhoops` for the WHOOP families and runs its own `StandardHRSource` for generic
    // straps , see AddDeviceWizard.

    /// The straps surfaced by the WHOOP present-scan (`scanForWhoops`), for the wizard's live list.
    /// Empty until a present-scan has discovered something; refreshed in place as RSSI updates.
    var discoveredWhoops: [(uuid: String, name: String, rssi: Int)] { ble.discoveredWhoops }

    /// True when the selected/connected strap is a WHOOP 5/MG. A thin window onto `BLEManager.isWhoop5`
    /// (its `selectedModel` is private) so a view can branch on the strap generation without reaching into
    /// the BLE layer. #864: the Smart-alarm card uses this to give a 5/MG owner the honest "saved but NOT
    /// armed until Experimental is on" copy, instead of hardcoding WHOOP 4.0. Mirrors the Android
    /// `LiveState.whoop5Detected` field the equivalent screen reads.
    var whoop5Detected: Bool { ble.isWhoop5 }

    /// Point the WHOOP scan at a specific family, then present nearby straps WITHOUT auto-connecting.
    /// `prepareForModelSwitch()` first clears any sticky bond/connection so the engine is idle, then
    /// `connect(model:)` selects the family + installs its framing (it sets the engine's private
    /// `selectedModel`, which `scanForWhoops()` scans for), and the immediate `scanForWhoops()` takes
    /// over the central in present-mode (it `stopScan()`s the connect's scan and re-arms a duplicate-
    /// allowing present scan). The persisted `selectedWhoopModel` is updated too, so a later real
    /// connect to the chosen strap targets the right family. All via existing public methods.
    func presentWhoopScan(model: WhoopModel) {
        UserDefaults.standard.set(model.rawValue, forKey: "selectedWhoopModel")
        ble.prepareForPresentScan(model: model) // idle for a family switch, but KEEP a live same-family bond (#74)
        ble.connect(model: model)             // select the family (sets engine selectedModel + framing)
        ble.scanForWhoops()                   // take over the central, present nearby straps only
    }

    /// End the WHOOP present-scan (idempotent). Call on leaving the wizard's pick step / on dismiss.
    func stopWhoopScan() { ble.stopWhoopScan() }

    /// Register a paired device and (optionally) make it the active one. The Add-a-device wizard's
    /// single write path: `add` upserts the row, and when `makeActive` is true `setActive` promotes it
    /// (the SourceCoordinator reacts to the active-device change and connects). No-op if the registry
    /// hasn't been wired yet (pre store-open) , the wizard is only reachable once it has.
    func registerDevice(_ device: PairedDevice, makeActive: Bool) {
        guard let registry = deviceRegistry else { return }
        registry.add(device)
        if makeActive {
            // `setActive` republishes `registry.$activeDeviceId`, which the read-spine subscription
            // (`readSpineCancellable`, wired in `wireSourceCoordinator`) observes and re-points the reads
            // off, so the dashboard follows a re-add without a one-shot call here. The explicit adopt below
            // is kept as a belt-and-braces immediate re-point (idempotent, so it's a safe no-op once the
            // subscription has also fired). The just-activated id IS `device.id` (`setActive` made it active).
            registry.setActive(device.id)
            Task { [weak self] in await self?.adoptActiveDevice(device.id) }
        }
    }

    #if os(iOS)
    /// Materialize Apple Health as a device and update the source that feeds Today.
    /// Only replaces the seeded WHOOP row while it is still a placeholder with no strap and no data;
    /// a physical or user-selected source always keeps priority.
    func refreshAfterAppleHealthSync(authorized: Bool, now: Date = Date()) async {
        await wireSourceCoordinator()
        guard let registry = deviceRegistry, let store = await repo.storeHandle() else {
            await repo.refresh()
            return
        }

        let current = registry.devices.first(where: { $0.id == registry.activeDeviceId })
        var currentHasRecentData = false
        if let current {
            let range = AppleWatchDevice.recentDayRange(now: now)
            let cutoff = Int(now.timeIntervalSince1970) - AppleWatchDevice.recentWindowDays * 86_400
            let latestHR = (try? await store.latestHRSampleTs(deviceId: current.id)) ?? nil
            let recentDaily = (try? await store.dailyMetrics(
                deviceId: current.id, from: range.from, to: range.to)) ?? []
            currentHasRecentData = (latestHR ?? 0) >= cutoff || !recentDaily.isEmpty
        }

        await AppleWatchDevice.registerIfAuthorized(
            registry: registry, store: store, authorized: authorized, now: now)
        guard registry.devices.contains(where: { $0.id == AppleWatchDevice.deviceId }) else {
            await repo.refresh()
            return
        }

        if AppleWatchDevice.shouldAutoActivate(
            current: current, currentHasRecentData: currentHasRecentData) {
            registry.setActive(AppleWatchDevice.deviceId)
            await adoptActiveDevice(AppleWatchDevice.deviceId)
        } else if registry.activeDeviceId == AppleWatchDevice.deviceId {
            // Covers relaunches: the row was already active, but the read spine may still be initializing.
            await adoptActiveDevice(AppleWatchDevice.deviceId)
            await repo.refresh()
        } else {
            await repo.refresh()
        }
    }
    #endif

    // MARK: - Oura adopt (factory-reset-and-adopt)

    /// The live adopt outcome of the active Oura ring, mirrored off the coordinator's live `OuraLiveSource`
    /// so the Add-device wizard can drive its "Taking over your ring" step to success or an honest Failed
    /// WITHOUT reaching into the BLE layer. nil when no Oura source is live or no adopt is in flight. PARITY:
    /// the Android wizard observes the same coarse outcome to leave its Adopting step.
    @Published private(set) var ouraAdoptPhase: OuraLiveSource.AdoptPhase = .idle
    /// The active Oura ring's honest needs-pairing message (mirrored off the live source), surfaced verbatim
    /// on the wizard's Failed step. nil when the ring is fine or no Oura source is live.
    @Published private(set) var ouraNeedsPairing: String?
    /// Combine subscriptions mirroring the live Oura source's `adoptPhase` / `needsPairing` into the two
    /// published properties above. Re-bound whenever the active Oura source changes.
    private var ouraAdoptCancellables = Set<AnyCancellable>()

    /// Take over a factory-reset Oura ring: grant the coordinator explicit adopt consent for THIS ring (so
    /// its live session may run the one-time key install, s3.2), register it active (which starts that live
    /// session), then begin mirroring its adopt outcome for the wizard. The irreversible-consent gate has
    /// ALREADY been passed in the wizard (the consent tick + the "Take over this ring?" confirm); this is the
    /// commit. Never prompts to make-active (the takeover IS the user's new active source).
    func adoptOuraRing(_ device: PairedDevice) {
        sourceCoordinator?.requestOuraAdopt(deviceId: device.id)
        // Reset the mirror so a previous attempt's outcome never leaks into this one.
        ouraAdoptPhase = .idle
        ouraNeedsPairing = nil
        registerDevice(device, makeActive: true)
        bindOuraAdoptMirror()
    }

    /// (Re)bind the adopt-outcome mirror to whichever `OuraLiveSource` the coordinator has live now and on
    /// every later swap. `flatMap` switches to the current source's `adoptPhase` (defaulting to `.idle` when
    /// there is no source), so the published value always tracks the live source without leaking subscriptions.
    private func bindOuraAdoptMirror() {
        ouraAdoptCancellables.removeAll()
        guard let coordinator = sourceCoordinator else { return }
        coordinator.$ouraSource
            .flatMap { source -> AnyPublisher<OuraLiveSource.AdoptPhase, Never> in
                source?.$adoptPhase.eraseToAnyPublisher()
                    ?? Just(.idle).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.ouraAdoptPhase = $0 }
            .store(in: &ouraAdoptCancellables)
        coordinator.$ouraSource
            .flatMap { source -> AnyPublisher<String?, Never> in
                source?.$needsPairing.eraseToAnyPublisher()
                    ?? Just(nil).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.ouraNeedsPairing = $0 }
            .store(in: &ouraAdoptCancellables)
    }

    /// How many on-screen surfaces currently want the realtime HR stream (the Live tab and the
    /// in-exercise LiveWorkoutView, which can be open at the same time , the workout sheet sits over
    /// Live, or is reached straight from the Workouts tab without Live ever appearing). The stream
    /// stays armed while ANY of them is visible, so a second surface arming it never disarms it out
    /// from under the first (#681 , a WHOOP 5/MG manual workout started without first opening Live got
    /// no live HR, so every sample was dropped and the session was silently discarded). Ref-counted to
    /// match Android's `realtimeWanters` (AppViewModel.requestRealtimeHr/releaseRealtimeHr).
    private var realtimeWanters = 0

    /// A surface that shows live HR appeared. Arms the realtime stream on the 0→1 edge , and ONLY on
    /// that edge blanks the stale smoothing window (#46) so a resume shows "," until a fresh sample
    /// lands, never re-clearing an already-live window when a second concurrent HR surface opens. The
    /// keep-alive re-arm goes through `ble.startRealtime()` directly, NOT here, so steady-state is
    /// untouched. Each surface must balance this with exactly one `stopRealtimeHR()` on disappear.
    func startRealtimeHR() {
        if realtimeWanters == 0 {
            resetSmoothing()
            ble.startRealtime()
        }
        realtimeWanters += 1
    }
    /// A live-HR surface went away. Stops the realtime stream only when the last one leaves (1→0 edge);
    /// the lightweight 0x2A37 HR keeps recording regardless. Clamped at 0 so an unbalanced extra stop
    /// can't drive the count negative and wedge the stream off.
    func stopRealtimeHR() {
        realtimeWanters = max(0, realtimeWanters - 1)
        if realtimeWanters == 0 { ble.stopRealtime() }
    }

    /// Re-issue the BLE realtime arm WITHOUT touching the ref-count , used when a fresh
    /// connection/bond lands while a surface is already showing live HR (Apple's `ble.startRealtime()`
    /// must be re-sent on a new connection). A no-op when nothing wants the stream, so a stray
    /// connection event can't arm it behind a closed Live tab. Mirrors that Android re-arms via its
    /// own keep-alive rather than re-calling `requestRealtimeHr` on reconnect.
    func rearmRealtimeIfWanted() {
        guard realtimeWanters > 0 else { return }
        ble.startRealtime()
    }
    /// Ask the strap for a fresh battery reading.
    func getBattery() { ble.refreshBattery() }

    /// Fire a haptic buzz on the strap. patternId=2 is the graduated buzz confirmed on-device;
    /// `loops` sets the length. Used by scheduled cues (coach zones, moment marks, biofeedback).
    /// Requires a bonded connection , no-op otherwise (the command characteristic is gated on bond).
    /// For a user-facing "buzz the strap now" action use `buzzStrapOnce()` instead (#921).
    func buzz(loops: UInt8 = 2) {
        ble.send(.runHapticsPattern, payload: [2, loops, 0, 0, 0])
    }

    /// #haptics (#1115): an IN-SESSION cue buzz, GATED by its per-event `HapticPrefs` toggle (default-off /
    /// opt-in, migrated-on for existing installs). Each in-session cue site passes its `gate` key so the
    /// enable check lives in ONE place rather than at every call site. The ungated `buzz` / `buzzStrapOnce`
    /// remain for ambient cues (which carry their own gates) and explicit user buzzes. Twin of Android
    /// `AppViewModel.buzz(loops, gate)`.
    func buzz(loops: UInt8 = 2, gate: String) {
        if HapticPrefs.enabled(gate) { buzz(loops: loops) }
    }

    /// One-shot user buzz (#921): the on-device-confirmed pattern (patternId=2, 3 loops) followed by
    /// RUN_ALARM, both written acknowledged. A bare RUN_HAPTICS_PATTERN write can be silently ignored
    /// (WHOOP 4.0 via the Siri shortcut) or dropped unacked on a busy link, so the Live "Buzz strap"
    /// button and the Buzz Strap App Intent both route through this single sequence.
    func buzzStrapOnce() {
        ble.buzzStrapOnce()
    }


    /// Tell the strap to STOP an in-progress haptic pattern (#769). The biofeedback layers (Breathe /
    /// "Calm me" / resonance) schedule a stream of buzzes; cancelling the app-side DispatchWorkItems stops
    /// scheduling NEW pulses but cannot recall a pattern the strap is already mid-way through. If the link
    /// then drops mid-pattern, the strap's UI/haptic manager can be left wedged on that pattern with no app
    /// able to clear it. STOP_HAPTICS (cmd 122, payload [0x00]) is the documented, reversible clear for
    /// WHOOP 4.0.
    ///
    /// WHOOP 5/MG CAVEAT: the 5/MG buzz rides the maverick 0x13 path (a one-shot, not a sustained pattern),
    /// and we have NOT confirmed the 5/MG honours cmd 122 on that path. `send` does not allow-list 122 for
    /// the 5/MG family, so on a 5/MG this is a no-op (logged "skipped"), not a guessed write. So this is
    /// BEST-EFFORT: it reliably clears a wedged WHOOP 4.0; on a 5/MG the one-shot nature already limits the
    /// wedge, and we deliberately do not invent an unverified stop opcode. Safe to call always (no-op when
    /// unbonded or when the family doesn't accept it).
    func stopHaptics() {
        ble.send(.stopHaptics, payload: [0x00])
    }

    // MARK: - Wrist-buzz mirror notifications (PR #577 , iOS only)
    //
    // iOS can't keep the strap buzz silent in a pocket the way macOS surfaces it on screen, so a wrist
    // buzz the user might miss (a long sedentary stretch, the smart-alarm wake) is ALSO posted as a
    // local notification. macOS keeps routing to its dedicated Notifications screen and never calls
    // these , `#if os(iOS)` makes them no-ops there so that path is untouched. Both are gated on the
    // same `notif.masterEnabled` master switch the iOS Automations "Wrist alerts" toggle (PR #572) and
    // the SedentaryDetector read, so turning wrist alerts off silences these too.

    /// The master wrist-alerts gate (PR #572). One key, shared with the iOS Automations toggle and the
    /// SedentaryDetector, so all three honour the same switch.
    static let wristAlertsMasterKey = "notif.masterEnabled"

    /// Post the local notification mirroring the inactivity (sedentary) wrist nudge. Called right after
    /// `BLEManager.maybeBuzzInactivity` fires its buzz (see crossLaneNotes). `minutes` = the seated bout
    /// length the detector reported. No-op on macOS and when wrist alerts are off.
    static func postInactivity(minutes: Int) {
        #if os(iOS)
        let body = minutes > 0
            ? String(localized: "You've been seated for about \(minutes) min. Time to move.")
            : String(localized: "Time to move. You've been seated a while.")
        postWristAlert(identifier: "inactivity-nudge", title: String(localized: "Move reminder"), body: body)
        #endif
    }

    /// Post the local notification mirroring the smart-alarm wake buzz. Called from the
    /// `onSmartAlarmFired` hook. No-op on macOS and when wrist alerts are off.
    static func postSmartAlarm() {
        #if os(iOS)
        postWristAlert(identifier: "smart-alarm-wake", title: String(localized: "Smart alarm"),
                       body: String(localized: "Good morning. Your smart alarm just woke you."))
        #endif
    }

    #if os(iOS)
    /// Shared post path: gate on the wrist-alerts master, then deliver only if the OS already authorized
    /// notifications (no second system prompt , BatteryNotifier-style status-only check). A fresh
    /// identifier per category means a new alert replaces the old one rather than stacking.
    private static func postWristAlert(identifier: String, title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: wristAlertsMasterKey) else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
    #endif

    /// Stable identifier base for the smart-alarm BACKUP wake notification(s). The every-day case uses
    /// this id directly; the per-weekday case fans out to "<base>-d<weekday>" so a re-arm replaces by id
    /// and never stacks. Kept separate from "smart-alarm-wake" (the strap-confirmed mirror) so the two
    /// never collide.
    private static let smartAlarmBackupId = "smart-alarm-wake-backup"
    private static var smartAlarmBackupIds: [String] {
        [smartAlarmBackupId] + (1...7).map { "\(smartAlarmBackupId)-d\($0)" }
    }

    /// Schedule a BEST-EFFORT repeating daily backup wake notification for the smart alarm (#4 + #6).
    ///
    /// The strap firmware alarm is one absolute instant and the mirror in `postSmartAlarm` only posts
    /// AFTER the strap reports it fired, so if the buzz fails or the phone is suspended past day one there
    /// was previously no OS-level wake at all. This adds a repeating `UNCalendarNotificationTrigger` that
    /// "lives in the notification center, not our process" (the WindDownNudge idiom), so it survives
    /// relaunch and keeps firing each chosen morning even with the app killed.
    ///
    /// HONEST: this is NOT a guaranteed loud alarm. A sideloaded build has no critical-alert entitlement,
    /// so iOS Focus / silent mode can still suppress the sound. The UI copy says to keep a real backup.
    ///
    /// Gated on the ALARM being enabled (its sole caller `applySmartAlarm()` already enforces that) plus
    /// notification permission — NOT the wrist-alerts master (#34): a wake backup must not depend on the
    /// unrelated HR/strain-alerts switch. When permission is undetermined the user is prompted here (they
    /// just enabled the alarm) and scheduled on grant, so the FIRST night is covered. Always removes the
    /// prior set first, so a re-arm replaces rather than stacks. `weekdays` empty = every day (single daily
    /// trigger); a non-empty set fans out to one weekday-pinned trigger per selected day. No-op on macOS.
    /// `log` (optional): strap-log sink for the not-authorized bail (#401 close-out) — a silent no-op left a
    /// user whose backup never fired with nothing in the log. The caller wraps the sink in a main-actor hop
    /// (the auth check completes off-main). Diagnostic only.
    static func scheduleSmartAlarmBackupNotification(minutes: Int, weekdays: Set<Int>,
                                                     log: ((String) -> Void)? = nil) {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        // Always clear BOTH the single and the per-day ids so switching modes (or editing the weekday set)
        // never leaves an orphaned trigger or double-fires.
        center.removePendingNotificationRequests(withIdentifiers: smartAlarmBackupIds)
        // #34: the backup follows THE ALARM, not the wrist-alerts master. This is only reached from
        // applySmartAlarm() with the alarm enabled, so the alarm being on IS the correct gate — a user who
        // sets a smart alarm but never turned on the separate wrist HR/strain alerts must still get a backup
        // wake. The old `notif.masterEnabled` guard suppressed it for exactly those users, so a strap that
        // couldn't arm left them with nothing.
        let valid = weekdays.filter { (1...7).contains($0) }
        // A non-empty selection that filters to nothing (only out-of-range numbers) has no day to fire on.
        if !weekdays.isEmpty && valid.isEmpty { return }

        // Build + add the repeating trigger(s). Factored so the already-authorized and the just-granted
        // paths schedule identically.
        func addRequests() {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Smart alarm")
            content.body = String(localized: "Backup wake: your smart alarm time is here.")
            content.sound = .default
            let hour = minutes / 60
            let minute = minutes % 60
            if weekdays.isEmpty {
                var comps = DateComponents()
                comps.hour = hour
                comps.minute = minute
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                center.add(UNNotificationRequest(identifier: smartAlarmBackupId, content: content, trigger: trigger))
            } else {
                for weekday in valid {
                    var comps = DateComponents()
                    comps.weekday = weekday   // Calendar weekday 1=Sun…7=Sat , fires weekly on that day
                    comps.hour = hour
                    comps.minute = minute
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                    center.add(UNNotificationRequest(identifier: "\(smartAlarmBackupId)-d\(weekday)",
                                                     content: content, trigger: trigger))
                }
            }
        }

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized:
                addRequests()
            case .notDetermined:
                // The user just enabled the alarm but was never asked for notification permission (nothing
                // else prompted — wrist alerts, which used to, may be off). Ask now, then schedule on grant
                // so the FIRST night is covered rather than only after some later re-arm.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { addRequests() }
                    else { log?("Smart alarm: backup notification NOT scheduled (notification permission denied)") }
                }
            default:
                log?("Smart alarm: backup notification NOT scheduled (notifications not authorized)")
            }
        }
        #endif
    }

    /// Cancel the smart-alarm backup wake notification(s). Called on disarm. No-op on macOS.
    static func cancelSmartAlarmBackupNotification() {
        #if os(iOS)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: smartAlarmBackupIds)
        #endif
    }

    /// Arm (or clear) the strap's firmware alarm from the smart-alarm settings. The firmware alarm
    /// fires even if the Mac is asleep / NOOP is closed. No-op until bonded (send is gated on bond).
    ///
    /// On iOS this ALSO (dis)arms the best-effort backup wake notification (#4 + #6): a repeating daily
    /// `UNCalendarNotificationTrigger` that survives suspend/relaunch, so a missed strap buzz still gets
    /// an OS-level wake. macOS keeps just the firmware alarm (the static helpers are no-ops there).
    func applySmartAlarm() {
        guard behavior.smartAlarmEnabled else {
            ble.disableStrapAlarm()
            Self.cancelSmartAlarmBackupNotification()
            return
        }
        guard let next = Self.nextSmartAlarmDate(minutes: behavior.smartAlarmMinutes,
                                                 weekdays: behavior.smartAlarmWeekdays) else {
            // No enabled weekday in the next week (only possible from a corrupted set) , disarm rather
            // than arm a misleading time the user never asked for.
            ble.disableStrapAlarm()
            Self.cancelSmartAlarmBackupNotification()
            return
        }
        ble.armStrapAlarm(at: next)
        // Replace (remove + re-add by stable identifier) on every re-arm so the backup never stacks.
        // The log sink hops to the main actor because the auth check completes off-main and LiveState is
        // @MainActor - the same Task hop the importTraceSink uses.
        Self.scheduleSmartAlarmBackupNotification(minutes: behavior.smartAlarmMinutes,
                                                  weekdays: behavior.smartAlarmWeekdays,
                                                  log: { [weak self] line in
                                                      Task { @MainActor in self?.live.append(log: line) }
                                                  })
    }

    /// Compute the next fire date for the smart alarm, honouring the weekday selection.
    /// - `minutes`: target wake time, minutes since local midnight.
    /// - `weekdays`: Calendar weekday numbers (1 = Sun … 7 = Sat) the alarm may fire on. Empty = every
    ///   day. Days outside 1…7 are ignored.
    /// Returns the next strictly-future date matching the time on an enabled weekday, scanning today
    /// plus the next 7 days, or nil if no enabled weekday falls in that range. Pure + side-effect-free
    /// so it can be unit-tested against a fixed clock.
    nonisolated static func nextSmartAlarmDate(minutes: Int,
                                               weekdays: Set<Int>,
                                               from now: Date = Date(),
                                               calendar cal: Calendar = .current) -> Date? {
        let valid = weekdays.filter { (1...7).contains($0) }
        // An empty input means "every day" (backward compatible). A non-empty selection that filters to
        // nothing (only out-of-range numbers) has no valid day to fire on, so it's nil, not a daily alarm.
        if !weekdays.isEmpty && valid.isEmpty { return nil }
        let hour = minutes / 60
        let minute = minutes % 60
        // Scan today (offset 0) through +7 days so a once-a-week alarm picked for "today, already
        // passed" still resolves to the same weekday next week.
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now),
                  let fire = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            else { continue }
            if fire <= now { continue }
            if weekdays.isEmpty { return fire }
            if valid.contains(cal.component(.weekday, from: fire)) { return fire }
        }
        return nil
    }

    /// Re-arms the single-instant firmware alarm once per day (just after local midnight) so a
    /// continuously-bonded strap keeps waking the user past the first fire. macOS stays running so this
    /// fires reliably; iOS additionally re-arms on foreground (it can't run timers while suspended).
    /// `applySmartAlarm` self-gates on `smartAlarmEnabled`, so this is a no-op when the alarm is off.
    private func scheduleDailySmartAlarmRearm() {
        smartAlarmRearmTimer?.invalidate()
        let cal = Calendar.current
        guard let firstFire = cal.nextDate(after: Date(),
                                           matching: DateComponents(hour: 0, minute: 1, second: 0),
                                           matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: firstFire, interval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; hop to the main actor for the @MainActor model.
            // applySmartAlarm self-gates on smartAlarmEnabled (and re-asserts the disarmed state if off).
            Task { @MainActor in self?.applySmartAlarm() }
        }
        RunLoop.main.add(timer, forMode: .common)
        smartAlarmRearmTimer = timer
    }

    // MARK: - Physical inputs / wear automation

    private func handleDoubleTap() {
        let now = Date()
        guard now.timeIntervalSince(lastDoubleTapAt) > 1.2 else { return }   // debounce repeats
        lastDoubleTapAt = now
        live.append(log: "Double-tap → \(behavior.doubleTapAction.label)")
        runMacAction(behavior.doubleTapAction, shortcut: behavior.doubleTapShortcut)
    }

    /// Run a configured Mac action. In-app actions (buzz/moment) stay on-device; lock + shortcuts
    /// go through MacActions.
    func runMacAction(_ kind: MacActionKind, shortcut: String) {
        switch kind {
        case .none: break
        case .lockScreen:
            if !MacActions.lockScreen() {
                #if os(macOS)
                MacActions.runShortcut("Lock Screen")   // login.framework unavailable , fall back to a Shortcut
                #endif
                // iOS can't lock the device and .lockScreen isn't selectable there, so no stray Shortcut launch.
            }
        case .buzzBack: buzz(loops: 1)
        case .markMoment: markMoment()
        case .sleepMark: markSleep()
        case .hapticClock: ble.buzzTimeNow(is24h: Self.localeUses24HourClock)
        case .runShortcut: MacActions.runShortcut(shortcut)
        }
    }

    /// Whether the user's locale formats time on a 24-hour clock , drives the Haptic Clock's hour
    /// encoding (#460) so a double-tap buzzes the time the way the user reads it. Derived from the
    /// locale's "j" (hour) template: a 12-hour locale includes the AM/PM ("a") symbol.
    static var localeUses24HourClock: Bool {
        let fmt = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: AppLanguage.activeLocale) ?? "h"
        return !fmt.contains("a")
    }

    /// Record a "moment" (double-tap marker) with a confirming buzz.
    func markMoment() { markMoment(at: Date()) }

    /// Record a "moment" at a specific time (used by the Siri/Shortcuts path, which captures the
    /// invocation time even though the app only drains the queue later when it becomes active).
    func markMoment(at date: Date) {
        moments.append(date)
        if moments.count > 500 { moments.removeFirst(moments.count - 500) }
        UserDefaults.standard.set(moments.map(\.timeIntervalSince1970), forKey: "moments")
        buzz(loops: 1)
        live.append(log: "Moment marked")
    }

    /// #461: record a "sleep mark" , a bedtime / wake / mid-night tap. Stored like moments (survives
    /// relaunch) and written as a distinct, greppable "Sleep mark @ HH:mm" line into the strap log so it
    /// rides along in the shared log / raw export. A single buzz confirms it registered. No start/end
    /// smarts yet (Phase 1): marks are logged in sequence; pairing into sleep bounds comes later.
    func markSleep() { markSleep(at: Date()) }
    func markSleep(at date: Date) {
        sleepMarks.append(date)
        if sleepMarks.count > 500 { sleepMarks.removeFirst(sleepMarks.count - 500) }
        UserDefaults.standard.set(sleepMarks.map(\.timeIntervalSince1970), forKey: "sleepMarks")
        buzz(loops: 1)
        let hhmm = DateFormatter()
        hhmm.locale = Locale(identifier: "en_US_POSIX")
        hhmm.dateFormat = "HH:mm"
        live.append(log: "Sleep mark @ \(hhmm.string(from: date))")
        // Persistence parity with Android's `AppViewModel.markSleep` (#461): also upsert the TYPED
        // `sleep_mark` metric-series row that the Sleep screen reads back (SleepView.logMark writes the
        // same row when the user taps a button). A physical double-tap can't choose bedtime vs wake, so
        // it defaults to `.bedtime` , the boundary the gesture most naturally marks. Idempotent by
        // (deviceId, day, key) through the repo's live store handle: no new Repository API, no schema
        // change. The UserDefaults list + buzz + freetext log line above are unchanged.
        let mark = SleepMark(type: .bedtime, at: date)
        Task { [weak self] in
            guard let self, let store = await self.repo.storeHandle() else { return }
            try? await store.upsertMetricSeries([mark.metricPoint], deviceId: self.repo.deviceId)
        }
    }

    private func handleWristChange(_ worn: Bool) {
        if worn {
            if !behavior.wristOnShortcut.isEmpty { MacActions.runShortcut(behavior.wristOnShortcut) }
        } else {
            #if os(macOS)
            // Auto-lock on wrist-off is a macOS-only affordance (the toggle is hidden on iOS, where a
            // third-party app can't lock the device). Guarding it here also stops a stray "Lock Screen"
            // Shortcut launch for any iOS user who toggled this on before it was gated off iPhone.
            if behavior.autoLockOnWristOff, !MacActions.lockScreen() { MacActions.runShortcut("Lock Screen") }
            #endif
            if !behavior.wristOffShortcut.isEmpty { MacActions.runShortcut(behavior.wristOffShortcut) }
        }
    }

    /// HR-zone haptic coaching: buzz when crossing into the top zone (ease off) or back to recovery.
    private func coachZone(_ hr: Int?) {
        guard behavior.zoneCoaching, live.bonded, live.worn, let hr, hr >= 30 else { return }
        guard profile.hrMax > 0 else { return }
        // #531: route the haptic coach through the profile's effective zone set (personalized when set,
        // conventional %HRmax otherwise) instead of hardcoded percentage bands.
        let zone = profile.hrZoneSet.zoneNumber(forBPM: Double(hr))
        defer { lastCoachZone = zone }
        guard lastCoachZone != -1, zone != lastCoachZone else { return }
        if zone == 5, lastCoachZone < 5 { buzz(loops: 3) }          // entered max , ease off
        else if zone <= 1, lastCoachZone > 1 { buzz(loops: 1) }     // recovered
    }

    /// Illness/strain early-warning (v5): the confounder-suppressed `IllnessSignalEngine`. For the last
    /// ~2 days vs a ~28-day personal baseline it z-scores resting HR, skin-temp deviation, HRV (negated)
    /// and respiration ORIENTED illness-ward, then the engine applies its minimum-corroboration gate,
    /// composite score, and , the differentiating part , same-day journal confounder suppression
    /// (alcohol / a hard-or-late workout / etc.) so a night out doesn't cry wolf. The journal context is
    /// read asynchronously, so this kicks a Task; the published `illnessSignal` + the `healthAlert`
    /// banner both come from the engine's single decision. On-device only, APPROXIMATE , not a diagnosis.
    // MARK: - Battery night-guard: learned bedtime cache

    /// The learned habitual midsleep (local seconds-of-day), cached for the battery night-guard.
    /// `repo.habitualMidsleepSec()` is an async whole-history store read, but the battery hook runs
    /// synchronously on the BLE callback, so the value is kept warm here instead. nil = cold-start
    /// (< `SleepStageTotals.habitualMinDays` nights) → `BatteryEstimator.bedtimeAlert` stays silent.
    private var habitualMidsleepCache: Int? = nil
    private var habitualMidsleepCachedAt: Date? = nil

    /// Refresh the cached habitual midsleep, at most hourly. The learner reads the full sleep history
    /// and the value moves on a timescale of WEEKS, so recomputing it on every `repo.$days` republish
    /// (several per rollup) would be pure cost for a number that cannot have changed.
    private func refreshHabitualMidsleep() {
        if let at = habitualMidsleepCachedAt, Date().timeIntervalSince(at) < 3600 { return }
        habitualMidsleepCachedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            self.habitualMidsleepCache = await self.repo.habitualMidsleepSec()
        }
    }

    /// Local time-of-day in seconds [0, 86400) — the clock the night-guard's bedtime window is in.
    /// Uses the CURRENT zone, so a traveller's window follows them rather than sticking to home time.
    static func localSecOfDayNow(_ now: Date = Date()) -> Int {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second], from: now)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    private func evaluateIllness(_ days: [DailyMetric]) {
        guard behavior.illnessWatch, days.count >= 14 else {
            healthAlert = nil; illnessSignal = nil; illnessDistance = nil; return
        }
        Task { [weak self] in
            guard let self else { return }
            // Confounder tags from the recent journal (within the last ~2 days). Read once, off the
            // engine's hot path , the engine only needs presence flags, not the rows.
            let recentDays = Set(days.suffix(2).map(\.day))
            let journal = await self.repo.journalEntries(days: 7)
            var ctxAlcohol = false, ctxHardWorkout = false, ctxAlreadyUnwell = false
            for e in journal where e.answeredYes && recentDays.contains(e.day) {
                let q = e.question.lowercased()
                if q.contains("alcohol") || q.contains("drink") { ctxAlcohol = true }
                if q.contains("workout") || q.contains("train") || q.contains("exercise") { ctxHardWorkout = true }
                if q.contains("sick") || q.contains("ill") || q.contains("unwell") { ctxAlreadyUnwell = true }
            }
            self.applyIllnessSignal(days, alcohol: ctxAlcohol, hardOrLateWorkout: ctxHardWorkout,
                                    alreadyUnwell: ctxAlreadyUnwell)
        }
    }

    /// Run the `IllnessSignalEngine` from the day history + the journal-derived confounder context, then
    /// publish the result + the legacy `healthAlert` banner string (kept for the existing banner surface).
    private func applyIllnessSignal(_ days: [DailyMetric], alcohol: Bool,
                                    hardOrLateWorkout: Bool, alreadyUnwell: Bool) {
        let previous = healthAlert
        let recent = Array(days.suffix(2))
        let base = Array(days.suffix(31).dropLast(3))    // ~28 days ending 3 days ago
        func mean(_ vals: [Double]) -> Double? { vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count) }
        func rm(_ kp: (DailyMetric) -> Double?) -> Double? { mean(recent.compactMap(kp)) }

        // Build each signal's illness-ward z against the personal baseline (Baselines.deviation). The
        // baseline is folded over the full pre-recent history; a trusted baseline (≥14 nights) is the
        // engine's gate for actually raising. Skin-temp is already a stored DEVIATION (°C), so it's
        // z-scored against a zero-centred personal spread; the others z-score the raw column.
        func signal(_ kp: (DailyMetric) -> Double?, cfgKey: String, illnessUp: Bool) -> (IllnessSignalEngine.SignalReading, Bool)? {
            guard let cfg = Baselines.metricCfg[cfgKey], let recentMean = rm(kp) else { return nil }
            let state = Baselines.foldHistory(base.map(kp), cfg: cfg)
            guard state.usable else { return (IllnessSignalEngine.SignalReading(zIllnessward: 0, present: false), false) }
            let dev = Baselines.deviation(recentMean, state: state)
            let z = illnessUp ? dev.z : -dev.z   // HRV drop is illness-ward → negate
            return (IllnessSignalEngine.SignalReading(zIllnessward: z), state.trusted)
        }

        let rhr = signal({ $0.restingHr.map(Double.init) }, cfgKey: "resting_hr", illnessUp: true)
        let hrv = signal({ $0.avgHrv }, cfgKey: "hrv", illnessUp: false)
        let resp = signal({ $0.respRateBpm }, cfgKey: "resp", illnessUp: true)
        // Skin-temp deviation: a stored °C delta. Build a small zero-centred state from its own recent
        // spread so a +0.6 °C reads as a meaningful z without needing a separate baseline column.
        var skin: (IllnessSignalEngine.SignalReading, Bool)? = nil
        if let recentSkin = rm({ $0.skinTempDevC }) {
            let z = recentSkin / 0.3     // ~0.3 °C ≈ one personal spread (matches skin_temp floorSpread)
            skin = (IllnessSignalEngine.SignalReading(zIllnessward: z), true)
        }

        let inputs = IllnessSignalEngine.Inputs(
            restingHR: rhr?.0, skinTemp: skin?.0, hrv: hrv?.0, respiration: resp?.0)

        // PARALLEL Mahalanobis distance on the SAME illness-ward z-vector (RHR up, HRV negated, skin-temp
        // up, respiration up). This NEVER gates the alert: the IllnessSignalEngine above remains the sole
        // fire gate. We compute it here only so the Heads-Up card can show a "how strong" confidence band
        // when the engine has already raised. nil where a reading is absent / not present (dropped from the
        // distance). correlation: nil = identity, validated to agree ~100% with the z-sum detector.
        func zIfPresent(_ r: (IllnessSignalEngine.SignalReading, Bool)?) -> Double? {
            guard let reading = r?.0, reading.present else { return nil }
            return reading.zIllnessward
        }
        let distanceFeatures = IllnessDistance.FeatureVector(
            restingHR: zIfPresent(rhr),
            rmssd: zIfPresent(hrv),       // hrv.zIllnessward is already the NEGATED HRV z
            skinTemp: zIfPresent(skin),
            respiration: zIfPresent(resp))
        illnessDistance = IllnessDistance.evaluate(features: distanceFeatures, correlation: nil)

        // baselineTrusted: require the HRV/RHR baselines to be trusted before the engine may raise.
        let trusted = (rhr?.1 ?? false) || (hrv?.1 ?? false)
        let context = IllnessSignalEngine.Context(
            alcohol: alcohol, hardOrLateWorkout: hardOrLateWorkout,
            alreadyUnwell: alreadyUnwell, baselineTrusted: trusted)

        // Caller-rendered phrases for the signals that fire (the engine surfaces only the firing ones).
        var labels: [String: String] = [:]
        if let r = rm({ $0.restingHr.map(Double.init) }), let b = mean(base.compactMap { $0.restingHr.map(Double.init) }), r > b {
            labels["restingHR"] = "RHR +\(Int((r - b).rounded()))"
        }
        if let r = rm({ $0.avgHrv }), let b = mean(base.compactMap { $0.avgHrv }), b > 0, r < b {
            labels["hrv"] = "HRV −\(Int(((1 - r / b) * 100).rounded()))%"
        }
        if let r = rm({ $0.skinTempDevC }), r > 0 {
            labels["skinTemp"] = "skin temp +\(String(format: "%.1f", r)) °C"
        }
        if let r = rm({ $0.respRateBpm }), let b = mean(base.compactMap { $0.respRateBpm }), r > b {
            labels["respiration"] = "respiration up"
        }

        let result = IllnessSignalEngine.evaluate(inputs, context: context, firedLabels: labels)
        illnessSignal = result
        // The amber banner string reflects the raised / already-unwell levels only (the calmer levels
        // surface in the Health hub's Heads-Up card, never as a scary banner).
        healthAlert = (result.level == .raised || result.level == .alreadyUnwell) ? result.copy : nil
        if let alert = healthAlert, previous == nil {
            IllnessNotifier.post(alert)
        }
    }

    /// #593: once-a-day "optimal strain reached" nudge. Reads the resolved today-row (the same
    /// logical-day resolution every dashboard surface uses), converts the stored 0-100 Effort to the
    /// 0-21 coupled axis with the SHIPPED formatter (so it matches every Effort read-out), and gates
    /// against the LOW end of today's recovery-derived optimal band (#43). The notifier's persisted
    /// day gate makes this safe to fire on every days republish; nil recovery (calibrating) yields a
    /// nil band → no target → no notification. Android twin: AppViewModel's days-collector call.
    func evaluateStrainTarget() {
        guard let row = repo.today else { return }
        StrainTargetNotifier.onDayUpdate(
            day: row.day,
            dayStrain21: row.strain.map { UnitFormatter.effortValue($0, scale: .whoop) },
            target21: CoupledView.optimalStrainRange(recovery: row.recovery)?.lowerBound,
            enabled: behavior.strainTargetNudge)
    }

    /// Re-run the illness watch over the cached history. Called when the Automations toggle
    /// flips , the repo.$days sink only fires on data changes, so a flip would otherwise wait
    /// for the next refresh.
    func reevaluateIllness() {
        evaluateIllness(repo.days)
    }

    // MARK: - v5 skin-temp suite engines (cycle phase + body clock)
    //
    // Run in the analytics pass (IntelligenceEngine calls this after it persists the night's scores) so
    // the Health hub's skin-temp cards read a ready snapshot. Both are pure StrandAnalytics engines fed
    // from the merged daily history; cycle awareness is gated behind the opt-in flag (default OFF) and
    // never computes , let alone surfaces , until the user turns it on.

    /// UserDefaults key for the cycle-awareness opt-in (default OFF , the most sensitive health category,
    /// manual-first). The Settings toggle + the card's opt-in CTA both write this single key.
    static let cycleAwarenessKey = "noopCycleAwareness"
    var cycleAwarenessEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.cycleAwarenessKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.cycleAwarenessKey) }
    }

    /// The user's "not for me" opt-out of cycle awareness — a respectful, USER-controlled hide, never
    /// age-based (menopause age varies too widely to infer). When true, the cycle-awareness OFFER is
    /// suppressed on Today and Health; the Automations toggle stays visible so it's reversible. Default
    /// false. Distinct from `cycleAwarenessEnabled` (active tracking): this hides the invitation itself.
    static let cycleAwarenessHiddenKey = "noopCycleAwarenessHidden"
    var cycleAwarenessHidden: Bool {
        get { UserDefaults.standard.bool(forKey: Self.cycleAwarenessHiddenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.cycleAwarenessHiddenKey) }
    }

    /// #polar-debug: whether a connecting Polar strap logs the model NOOP identifies it as (+ its PMD/HRV
    /// capability summary) to the strap log. Default off; the Test Centre only exposes the toggle when a
    /// Polar strap is paired. Diagnostic-only — nothing gates behaviour on it. Twin of Android
    /// `NoopPrefs.KEY_POLAR_DEBUG_LOGGING`.
    static let polarDebugLoggingKey = "noopPolarDebugLogging"
    var polarDebugLogging: Bool {
        get { UserDefaults.standard.bool(forKey: Self.polarDebugLoggingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.polarDebugLoggingKey) }
    }

    /// #1284 residual 3 (EXPERIMENTAL, default OFF): generation-side 0x49-onset keying for Oura sleep. When
    /// on, an Oura hypnogram persist keys its startTs on the rounded 0x49 onset (the stable per-night anchor)
    /// and a completeness guard suppresses/replaces a duplicate re-serve BEFORE it is banked — closing the
    /// window where the wrong night shows until the next analyze pass. Off = the shipped end-anchored persist.
    /// A hardware-validation toggle (Test Centre); no effect for a user with no Oura ring.
    static let ouraOnsetKeyingKey = "noopOuraOnsetKeying"
    var ouraOnsetKeying: Bool {
        get { UserDefaults.standard.bool(forKey: Self.ouraOnsetKeyingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.ouraOnsetKeyingKey) }
    }

    /// Recompute the v5 skin-temp suite snapshots (cycle phase + body clock) from the current history.
    /// Called from the analytics pass and when the cycle opt-in flips. Honest-nil throughout: cycle is
    /// nil unless opted in; circadian is nil unless a usable activity profile exists.
    func refreshV5Signals() async {
        await computeCyclePhase()
        await computeCircadianPhase()
    }

    /// Cycle-phase awareness from the nightly skin-temperature shift (+ luteal RHR rise / HRV drop). Each
    /// night is z-scored against the personal baseline, then `CyclePhaseEngine.classify` reads the run.
    /// Gated behind the opt-in flag; clears the published result the moment it's turned off.
    private func computeCyclePhase() async {
        guard cycleAwarenessEnabled else { cyclePhase = nil; cycleCurve = []; return }
        let days = repo.days
        guard let tempCfg = Baselines.metricCfg["skin_temp"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let hrvCfg = Baselines.metricCfg["hrv"] else { return }

        // The nightly absolute skin-temp mean isn't in repo.days (only the °C DEVIATION is), so z-score
        // the deviation against its own folded spread , a zero-centred personal baseline. RHR + HRV
        // z-score their raw columns. Oldest→newest.
        let sorted = days.sorted { $0.day < $1.day }
        let skinState = Baselines.foldHistory(sorted.map { $0.skinTempDevC }, cfg: tempCfg)
        let rhrState = Baselines.foldHistory(sorted.map { $0.restingHr.map(Double.init) }, cfg: rhrCfg)
        let hrvState = Baselines.foldHistory(sorted.map { $0.avgHrv }, cfg: hrvCfg)

        var nights: [CyclePhaseEngine.Night] = []
        var curve: [Double] = []
        for d in sorted {
            let tempZ = d.skinTempDevC.map { skinState.usable ? Baselines.deviation($0, state: skinState).z : $0 / 0.3 }
            let rhrZ = (rhrState.usable ? d.restingHr.map { Baselines.deviation(Double($0), state: rhrState).z } : nil)
            let hrvZ = (hrvState.usable ? d.avgHrv.map { Baselines.deviation($0, state: hrvState).z } : nil)
            nights.append(CyclePhaseEngine.Night(day: d.day, tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ))
            if let fused = CyclePhaseEngine.fusedIndex(tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ) { curve.append(fused) }
        }
        // Optional user-entered cycle-day-1 anchors live under the isolated `noop-cycle` source.
        // The pure engine cross-validates them against the temperature shift rather than trusting a
        // mistimed log blindly.
        let loggedPeriodStarts = await repo.periodStarts()
        cyclePhase = CyclePhaseEngine.classify(nights,
                                               baselineUsable: skinState.usable,
                                               loggedPeriodStarts: loggedPeriodStarts)
        cycleCurve = curve
    }

    /// Body-clock phase estimate. Builds a coarse per-hour activity profile from the last ~14 days of
    /// downsampled HR buckets (HR amplitude is a usable rest/activity rhythm proxy when raw motion isn't
    /// to hand), then fits the cosinor. nil when there isn't enough to read.
    private func computeCircadianPhase() async {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - 14 * 86_400
        let buckets = await repo.hrBuckets(from: from, to: now, bucketSeconds: 3_600)
        guard buckets.count >= 24 else { circadianPhase = nil; return }
        let tz = TimeZone.current.secondsFromGMT()
        // Pool HR by LOCAL hour-of-day → mean bpm per hour as the activity proxy (higher HR ≈ more active).
        var sums = [Double](repeating: 0, count: 24)
        var counts = [Int](repeating: 0, count: 24)
        var daySet = Set<Int>()
        for b in buckets {
            let local = b.ts + tz
            let hour = (local % 86_400 + 86_400) % 86_400 / 3_600
            sums[hour] += b.bpm; counts[hour] += 1
            daySet.insert(local / 86_400)
        }
        let bins: [CircadianEngine.ActivityBin] = (0..<24).compactMap { h in
            counts[h] > 0 ? CircadianEngine.ActivityBin(hour: Double(h), activity: sums[h] / Double(counts[h])) : nil
        }
        guard bins.count >= 6 else { circadianPhase = nil; return }
        // Habitual wake from the most recent night's banked wake, falling back to a 07:00 default.
        let wakeHour = habitualWakeHour() ?? 7.0
        circadianPhase = CircadianEngine.estimatePhase(
            bins: bins, daysObserved: daySet.count, habitualWakeHour: wakeHour)
    }

    /// A coarse habitual wake hour (local) from the most recent banked sleep session's end time, for the
    /// circadian schedule-offset comparison. nil when no sleep is banked.
    private func habitualWakeHour() -> Double? {
        guard let last = repo.sleeps.last else { return nil }
        let tz = TimeZone.current.secondsFromGMT()
        let local = (last.endTs + tz) % 86_400
        return Double((local + 86_400) % 86_400) / 3_600.0
    }

    // MARK: - v5 local multi-device fusion adapter
    //
    // Assemble today's per-source values per metric and run `FusionResolver` so the "Your Data, Fused"
    // screen (FusedRecordView) can show the best-sourced number + provenance + agreement. This does NOT
    // touch the core resolvedSeries waterfall , it's an additive read that reuses the rows the store
    // already holds, exactly the seam the view's header documents.

    /// Build today's fused record (best signal per metric across every source, with agreement). Reads each
    /// declared-fusable metric's latest per-source daily value, runs the pure `FusionResolver`, and maps
    /// the result into the view's `FusedRecord`. Honest single-source degradation falls out of the engine
    /// (a one-WHOOP user gets `.single` agreement and `contributingSourceCount == 1`).
    func buildTodayFusedRecord() async -> FusedRecord {
        guard let store = await repo.storeHandle() else {
            return FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0)
        }
        // The metrics surfaced, in importance-first display order, with a label + accent.
        let specs: [(key: String, label: String, accent: String?)] = [
            ("rhr", "Resting HR", nil),
            ("hrv", "HRV", nil),
            ("sleep_total_min", "Sleep", nil),
            ("steps", "Steps", nil),
            ("skin_temp", "Skin temp", nil),
            ("spo2", "Blood oxygen", nil),
        ]
        // Every source that could carry a value, mapped to its stored device id. (FusionSource.rawValue
        // IS the canonical source id, but the strap's real id is `deviceId`/`computed` , map explicitly.)
        let sources: [(FusionSource, String)] = [
            (.whoopImport, deviceId),
            (.noopComputed, deviceId + "-noop"),
            (.appleHealth, appleDeviceId),
            (.xiaomiBand, FusionSource.xiaomiBand.rawValue),
        ]

        let now = Date()
        let fromDay = Repository.dayString(now.addingTimeInterval(-3 * 86_400))
        let toDay = Repository.dayString(now.addingTimeInterval(86_400))

        // Read each source's daily rows once, then pick the freshest per metric for the latest day.
        var rowsBySource: [FusionSource: DailyMetric] = [:]
        for (src, id) in sources {
            let rows = (try? await store.dailyMetrics(deviceId: id, from: fromDay, to: toDay)) ?? []
            if let latest = rows.sorted(by: { $0.day < $1.day }).last { rowsBySource[src] = latest }
        }
        guard !rowsBySource.isEmpty else {
            return FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0)
        }

        var fusedRows: [FusedRow] = []
        var contributingSources = Set<FusionSource>()
        for spec in specs {
            var inputs: [FusionInput] = []
            for (src, daily) in rowsBySource {
                if let v = Self.fusionColumn(key: spec.key, day: daily) {
                    inputs.append(FusionInput(source: src, value: v))
                    contributingSources.insert(src)
                }
            }
            guard let point = FusionResolver.resolve(metricKey: spec.key, inputs: inputs) else { continue }
            fusedRows.append(FusedRow(point: point, label: spec.label, accentHex: spec.accent))
        }

        // The day-owner = the highest-priority source that actually contributed (the scores' single owner).
        let owner = contributingSources.min(by: {
            MetricArbitrationPolicy.sourcePriority($0) < MetricArbitrationPolicy.sourcePriority($1)
        })
        return FusedRecord(rows: fusedRows, dayOwner: owner,
                           contributingSourceCount: contributingSources.count)
    }

    /// The DailyMetric column a fusion metric key maps to (mirrors Repository.dailyColumn for the keys
    /// the fused record surfaces). nil when the source row doesn't carry that metric.
    private static func fusionColumn(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "rhr":             return d.restingHr.map(Double.init)
        case "hrv":             return d.avgHrv
        case "sleep_total_min": return d.totalSleepMin
        case "steps":           return d.steps.map(Double.init)
        case "skin_temp":       return d.skinTempDevC
        case "spo2":            return d.spo2Pct
        default:                return nil
        }
    }

    /// Import a Whoop CSV export (.zip or folder) → on-device store, then refresh the dashboard.
    /// A picked import file made safe to read. On iOS the security-scoped , and possibly
    /// iCloud-placeholder , URL is coordinated and COPIED into the app's temp directory, so the
    /// importer reads a stable LOCAL file. That's what makes import work for iCloud Drive files (they
    /// arrive as un-downloaded placeholders that ZIPFoundation can't open in place) and removes the
    /// scoped-access timing fragility that blocked iPhone imports (#179). On macOS the picked URL is
    /// read in place. `cleanup()` removes the temp copy AND the original `Documents/Inbox/` copy that
    /// `UIDocumentPickerViewController(asCopy: true)` leaves behind , a multi-GB Apple Health
    /// `export.zip` parked there was the runaway "Documents & Data" growth in #590 (one import → the
    /// store rows AND a permanent ~19 GB Inbox duplicate the OS never reclaims). Sendable so it can
    /// cross the actor boundary.
    struct ImportFile: Sendable {
        let url: URL
        private let temp: URL?
        /// The picker's `asCopy:true` drop in `Documents/Inbox/`, deleted on cleanup so it can't
        /// accumulate. nil on macOS (the URL is read in place, nothing to reclaim).
        private let inboxOriginal: URL?
        init(url: URL, temp: URL?, inboxOriginal: URL? = nil) {
            self.url = url; self.temp = temp; self.inboxOriginal = inboxOriginal
        }
        func cleanup() {
            if let temp { try? FileManager.default.removeItem(at: temp) }
            if let inboxOriginal, Self.isInImportInbox(inboxOriginal) {
                try? FileManager.default.removeItem(at: inboxOriginal)
            }
        }

        /// Only ever delete files the picker placed in OUR app's `Documents/Inbox/` , never a
        /// user-chosen in-place file on macOS or an iCloud URL outside the sandbox. The guard keeps
        /// `cleanup()` from removing anything the user still owns.
        static func isInImportInbox(_ url: URL) -> Bool {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return false }
            let inbox = docs.appendingPathComponent("Inbox").standardizedFileURL.path
            let candidate = url.standardizedFileURL.path
            return candidate.hasPrefix(inbox + "/")
        }
    }

    /// Runs off the main actor (nonisolated) so copying a large export never blocks the UI; the
    /// caller holds the security scope (process-wide) for the duration.
    nonisolated static func materializeForImport(_ picked: URL) async throws -> ImportFile {
        #if os(iOS)
        let ext = picked.pathExtension.isEmpty ? "dat" : picked.pathExtension
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-import-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        var coordError: NSError?
        var ioError: Error?
        // .forUploading materialises an iCloud placeholder and gives a stable snapshot to copy from.
        NSFileCoordinator().coordinate(readingItemAt: picked, options: [.forUploading], error: &coordError) { readURL in
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: readURL, to: dst)
            } catch { ioError = error }
        }
        if let coordError { throw coordError }
        if let ioError { throw ioError }
        // The picked URL is the picker's own `asCopy:true` duplicate in Documents/Inbox; pass it
        // through so cleanup() can reclaim it (it's the original of `dst`, not a user file).
        return ImportFile(url: dst, temp: dst, inboxOriginal: picked)
        #else
        return ImportFile(url: picked, temp: nil)
        #endif
    }

    /// One-shot launch sweep of `Documents/Inbox/`: deletes any stale `asCopy:true` picker drops a
    /// previous build left behind before `cleanup()` reclaimed them (#590). Best-effort, off-main, and
    /// safe , `Inbox` only ever holds picker hand-offs, never user data. Skips files newer than 60 s so
    /// it can't race an import that's mid-flight at launch.
    nonisolated static func purgeImportInbox() {
        #if os(iOS)
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let inbox = docs.appendingPathComponent("Inbox")
        guard let items = try? fm.contentsOfDirectory(at: inbox,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: []) else { return }
        let cutoff = Date().addingTimeInterval(-60)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }   // leave an in-flight hand-off alone
            try? fm.removeItem(at: item)
        }
        #endif
    }

    func importWhoop(url: URL) {
        beginImport(.whoop)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.whoop, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .whoopExport, url: local.url)
                let summary = try await WhoopImporter.importExport(url: local.url, into: store,
                                                                   deviceId: deviceId, trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                await repo.refresh()
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))-\(f.string(from: b))"
                } else { span = "" }
                finishImport(.whoop, summary: "Imported \(summary.recordCount) records\(span)")
            } catch {
                finishImport(.whoop, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    /// Import an Apple Health export (export.zip) , streams + aggregates per-day into the store
    /// under the `apple-health` source, then refreshes. Large exports take ~1–2 minutes.
    func importXiaomi(url: URL) {
        beginImport(.xiaomi)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.xiaomi, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .xiaomiBand, url: local.url)
                let summary = try await XiaomiImporter.importExport(url: local.url, into: store,
                                                                    trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                await repo.refresh()
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))-\(f.string(from: b))"
                } else { span = "" }
                let days = summary.countsByCategory["days"] ?? 0
                let sleeps = summary.countsByCategory["sleepSessions"] ?? 0
                finishImport(.xiaomi, summary: "Imported \(days) days · \(sleeps) sleeps\(span)")
            } catch {
                finishImport(.xiaomi, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    func importAppleHealth(url: URL) {
        beginImport(.appleHealth)
        // FIX 2(c): run the parse+writes at `.utility` so a large Apple Health import yields to UI
        // rendering instead of inheriting the user-initiated QoS of the calling tap , the import's bulk
        // work was contending with the main actor and contributing to the transient post-import lag.
        Task(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.appleHealth, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .appleHealth, url: local.url)
                let summary = try await AppleHealthImport.importExport(url: local.url, into: store,
                                                                       deviceId: appleDeviceId, trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                await repo.refresh()
                // #833/v7.7.2: an Apple Health import may write ONLY body-composition series (weight/body_fat/
                // lean_mass/bmi/vo2max), which live in metricSeries OUTSIDE refresh()'s diff over daily/sleep/
                // vitals, so refresh() may not bump `refreshSeq`. AppleHealthView's re-mount cache keys on
                // `refreshSeq`, so it would keep serving the pre-import snapshot. Explicitly drop the cache so
                // the next visit re-reads the freshly imported data. (refresh() alone is insufficient here.)
                repo.appleHealthCache = nil
                repo.appleHealthLoadedSeq = -1
                finishImport(.appleHealth, summary: "Imported \(summary.recordCount) records")
            } catch {
                finishImport(.appleHealth, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    // MARK: - Storage diagnostics (#590 , StorageView)

    /// A point-in-time snapshot of where the app's on-disk footprint is going, for the Storage screen.
    /// All sizes in bytes; `db` is nil only for an unopened/in-memory store.
    struct StorageReport: Equatable, Sendable {
        var db: Int64?
        var inbox: Int64
        var importTemp: Int64
    }

    /// Gather the storage report off the main actor: the GRDB file (+ WAL/SHM) from the store, plus the
    /// `Documents/Inbox/` picker-drop directory and the import temp files this app writes.
    func storageReport() async -> StorageReport {
        let db = await repo.storeHandle()?.databaseFileSizeBytes()
        let inbox = Self.inboxSizeBytes()
        let temp = Self.importTempSizeBytes()
        return StorageReport(db: db, inbox: inbox, importTemp: temp)
    }

    /// Total bytes in `Documents/Inbox/` (the picker's `asCopy:true` drops). 0 on macOS / when absent.
    nonisolated static func inboxSizeBytes() -> Int64 {
        #if os(iOS)
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return 0 }
        return directorySizeBytes(docs.appendingPathComponent("Inbox"))
        #else
        return 0
        #endif
    }

    /// True for any scratch file/dir NOOP itself writes into the temp directory , import copies, the
    /// decompressed export.xml, exports, backups, raw captures: every one is prefixed `noop-`. #590: the
    /// import decompresses `export.xml` to a `noop-health-*` temp file (up to 8 GB), but a previous build
    /// only matched `noop-import-*`, so an interrupted import stranded multi-GB extractions the Storage
    /// screen never saw OR reclaimed. Matching the shared `noop-` prefix counts + sweeps them all and is
    /// future-proof. Safe: the temp dir is NOOP's private sandbox and the 60 s in-flight guard in
    /// `purgeImportTemp` protects a live import.
    nonisolated static func isNoopTempScratch(_ name: String) -> Bool { name.hasPrefix("noop-") }

    /// Total bytes of NOOP's own `noop-*` temp scratch (a crash mid-import can strand a multi-GB one).
    /// Recurses into directories (the Xiaomi importer stages a `noop-xiaomi-*` folder).
    nonisolated static func importTempSizeBytes() -> Int64 {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { return 0 }
        var total: Int64 = 0
        for item in items where isNoopTempScratch(item.lastPathComponent) {
            let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true { total += directorySizeBytes(item) }
            else { total += Int64(vals?.fileSize ?? 0) }
        }
        return total
    }

    /// Sum every regular file under `dir` (one level , Inbox is flat). Best-effort; missing dir → 0.
    nonisolated private static func directorySizeBytes(_ dir: URL) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { return 0 }
        var total: Int64 = 0
        for item in items {
            let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true { total += directorySizeBytes(item) }
            else { total += Int64(vals?.fileSize ?? 0) }
        }
        return total
    }

    /// The Storage screen's "Clean up" action: purge the Inbox + stranded import temps, then truncate
    /// the WAL so the freed pages return to the OS. Returns a fresh report so the screen updates. Safe ,
    /// Inbox/temp hold only picker hand-offs + this app's own temp copies, never user data or live rows.
    @discardableResult
    func cleanUpStorage() async -> StorageReport {
        Self.purgeImportInbox()
        Self.purgeImportTemp()
        if let store = await repo.storeHandle() { try? await store.checkpointWAL() }
        return await storageReport()
    }

    /// Remove NOOP's stranded `noop-*` temp scratch (import copies, the multi-GB `noop-health-*`
    /// export.xml an interrupted import leaves behind , #590, exports, backups, raw captures). Mirrors
    /// `purgeImportInbox`'s 60 s in-flight guard so a concurrent import/export isn't disturbed.
    nonisolated static func purgeImportTemp() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        let cutoff = Date().addingTimeInterval(-60)
        for item in items where isNoopTempScratch(item.lastPathComponent) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fm.removeItem(at: item)
        }
    }

    /// Handle a `noop://import-health` deep link (PR #581), the HealthKit-free Shortcuts import for
    /// sideloaded installs. Custom URL schemes are forgeable by other apps/sites, so this only decodes
    /// and stages the payload. The iOS shell shows a confirmation alert before `confirmHealthImport()`
    /// writes anything into the `apple-health` source.
    func handleHealthImportURL(_ url: URL) {
        switch ShortcutHealthImport.prepare(url: url) {
        case .success(let pending):
            pendingShortcutHealthImport = pending
        case .failure(let outcome):
            beginImport(.appleHealth)
            Task { await finishShortcutHealthImport(outcome) }
        }
    }

    func cancelPendingHealthImport() {
        pendingShortcutHealthImport = nil
    }

    func confirmPendingHealthImport() {
        guard let pending = pendingShortcutHealthImport else { return }
        pendingShortcutHealthImport = nil
        beginImport(.appleHealth)
        Task {
            guard let store = await repo.storeHandle() else {
                finishImport(.appleHealth, summary: "Couldn't open the local store.", failed: true)
                return
            }
            let outcome = await ShortcutHealthImport.ingest(prepared: pending, into: store)
            await finishShortcutHealthImport(outcome)
        }
    }

    private func finishShortcutHealthImport(_ outcome: ShortcutHealthImport.Outcome) async {
        switch outcome {
        case .imported(let days, let workouts):
            await repo.refresh()
            // #833/v7.7.2: the Shortcuts import writes body-composition series (e.g. weight) into
            // metricSeries, which sits OUTSIDE refresh()'s diff, so refresh() may leave `refreshSeq`
            // unchanged and AppleHealthView's re-mount cache would serve stale data. Drop the cache so the
            // next visit re-reads. (Same reasoning as the file-import path above.)
            repo.appleHealthCache = nil
            repo.appleHealthLoadedSeq = -1
            let w = workouts > 0 ? " · \(workouts) workouts" : ""
            finishImport(.appleHealth, summary: "Imported \(days) days\(w)")
        case .nothingToImport:
            finishImport(.appleHealth, summary: "Nothing new to import.")
        case .rejected(let reason):
            finishImport(.appleHealth, summary: reason, failed: true)
        }
    }

    /// Marks a source as importing and clears only that source's old status text + failure flag.
    private func beginImport(_ source: DataSourceImportKind) {
        activeImportSource = source
        switch source {
        case .whoop:
            whoopImportSummary = nil
            whoopImportFailed = false
        case .appleHealth:
            appleHealthImportSummary = nil
            appleHealthImportFailed = false
        case .xiaomi:
            xiaomiImportSummary = nil
            xiaomiImportFailed = false
        }
    }

    /// Stores the completed import summary (and typed failure flag) on the matching source card.
    private func finishImport(_ source: DataSourceImportKind, summary: String, failed: Bool = false) {
        switch source {
        case .whoop:
            whoopImportSummary = summary
            whoopImportFailed = failed
        case .appleHealth:
            appleHealthImportSummary = summary
            appleHealthImportFailed = failed
        case .xiaomi:
            xiaomiImportSummary = summary
            xiaomiImportFailed = failed
        }
        activeImportSource = nil
    }
}
