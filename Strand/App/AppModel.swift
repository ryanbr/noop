import SwiftUI
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

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

    /// Shared device id for both live capture (BLEManager) and imported history.
    let deviceId = "my-whoop"
    /// Source id for imported Apple Health data (stored beside Whoop for per-source pages + consensus).
    let appleDeviceId = "apple-health"
    /// Observable snapshot driven by the BLE engine (connection, HR, battery, log).
    let live: LiveState
    /// CoreBluetooth engine — scans, connects, bonds, streams.
    let ble: BLEManager
    /// Read model over the on-device store (dashboard + detail screens).
    let repo: Repository
    /// User profile (age/sex/body/HR-max) for zones, calories, baselines.
    let profile = ProfileStore()
    /// Behaviour settings: double-tap action, wear automation, zone coaching, smart alarm, illness watch.
    let behavior = BehaviorStore()
    /// On-device WHOOP-style recovery/strain/sleep computation from raw strap streams.
    let intelligence: IntelligenceEngine

    /// Opt-in AI coach (bring-your-own-key) — the one networked feature, off until the user enables it.
    let coach: AICoachEngine

    /// Observable cache over the paired-device registry; `activeDeviceId` drives the source coordinator.
    /// Built lazily once the store opens (see `wireSourceCoordinator`). nil until then — with no generic
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

    /// Timestamps of "sleep marks" tapped on the strap (#461) — bedtime / wake / mid-night marks the
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

    /// A manual workout in progress. `samples` accumulate from the smoothed live `bpm`; `liveStrain`
    /// is recomputed as the window grows so the active card can show strain building in real time.
    struct ActiveWorkout: Equatable {
        let start: Date
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
    // than re-deriving. All opt-in / honest-nil — a nil result means "not enough data / not enabled".
    @Published var illnessSignal: IllnessSignalEngine.Result?
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
    // Legacy experimental stress-nudge state (the older `behavior.stressNudge` buzz path) — a slow HRV
    // baseline + a rate limiter, kept so that toggle still works independently of the L3 check-in.
    private var hrvBaseline: Double = 0
    private var lastStressBuzzAt: Date = .distantPast

    /// Import source currently writing to the local store, if any.
    @Published private var activeImportSource: DataSourceImportKind?
    /// Last WHOOP export import result surfaced in the WHOOP card.
    @Published var whoopImportSummary: String?
    /// Last Apple Health import result surfaced in the Apple Health card.
    @Published var appleHealthImportSummary: String?
    /// Last Xiaomi / Mi Band import result surfaced in the Mi Band card.
    @Published var xiaomiImportSummary: String?
    /// Typed failure flags per source — the summary's warning styling reads these instead of
    /// substring-matching the human-readable message (which misses errors like "Couldn't open
    /// the local store."). Surfaced on both the Data Sources cards and the onboarding import step.
    @Published var whoopImportFailed = false
    @Published var appleHealthImportFailed = false
    @Published var xiaomiImportFailed = false

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

    /// Smoothed, display-ready live heart rate — median over a short window, spike-filtered.
    /// Every screen should show THIS, not the raw per-beat value (which swings with HRV).
    @Published var bpm: Int?
    private var hrWindow: [(t: Date, v: Double)] = []
    private var hrCancellables = Set<AnyCancellable>()
    /// Daily re-arm timer for the single-instant firmware smart alarm (see scheduleDailySmartAlarmRearm).
    private var smartAlarmRearmTimer: Timer?

    init() {
        let live = LiveState()
        self.live = live
        self.ble = BLEManager(state: live, deviceId: "my-whoop")
        self.repo = Repository(deviceId: "my-whoop")
        self.coach = AICoachEngine(repo: repo)
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: "my-whoop")
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
        }
        // HR-zone haptic coaching watches the smoothed bpm.
        $bpm.sink { [weak self] hr in self?.coachZone(hr) }.store(in: &hrCancellables)
        // Illness/strain early-warning recomputes when the daily history changes.
        repo.$days.sink { [weak self] days in self?.evaluateIllness(days) }.store(in: &hrCancellables)
        // Re-arm the strap's firmware alarm whenever it (re)bonds. A smart-alarm time changed while the
        // strap was away never reached it — the send is gated on bond — so the strap kept the OLD time
        // and fired at it (#59). removeDuplicates() fires once per bond; gated on enabled so a disabled
        // alarm doesn't disarm on every reconnect.
        live.$bonded.removeDuplicates().sink { [weak self] bonded in
            guard let self, bonded, self.behavior.smartAlarmEnabled else { return }
            self.applySmartAlarm()
        }.store(in: &hrCancellables)
        // The firmware alarm is a single absolute instant with no recurrence, and was re-armed ONLY on
        // a (re)bond or a settings change. A strap that stays continuously bonded (a Mac in range) would
        // fire once and never re-arm — silent from day two. Re-arm daily so an always-on session keeps
        // waking the user.
        scheduleDailySmartAlarmRearm()
        // Re-apply "Continuous HRV capture" on every (re)bond: if on, the strap should hold the dense
        // realtime stream armed even with no Live screen open, so it banks beat-to-beat R-R 24/7 for
        // better overnight HRV/recovery/sleep. The BLE reconciler arms it on the off→on edge; pushing it
        // here (and at the init tail) covers a fresh launch and every reconnect. (See PuffinExperiment.)
        live.$bonded.removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            self.ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
        }.store(in: &hrCancellables)
        // A completed backfill has just written strap history. Refresh the dashboard cache,
        // but leave heavyweight analysis to its own guarded/background-friendly path.
        live.$lastSyncedAt
            .dropFirst()
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshAfterCompletedBackfill() }
            }
            .store(in: &hrCancellables)

        moments = (UserDefaults.standard.array(forKey: "moments") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
        sleepMarks = (UserDefaults.standard.array(forKey: "sleepMarks") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }

        AppModel.shared = self   // publish for App Intents (Shortcuts) — see the static above (#42)

        // Seed the BLE client with the persisted "Continuous HRV capture" intent so `wantsRealtime`
        // reflects it from launch — the reconciler then arms the dense stream as soon as the strap bonds
        // (and the bond sink above re-applies it on every reconnect).
        ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)

        // Turn the strap's offloaded raw data into dashboard scores on launch and every 15
        // minutes, so recovery / strain / sleep populate from the strap itself with no import.
        // IntelligenceEngine computes, persists under "my-whoop-noop", and refreshes the dashboard.
        Task { [weak self] in
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
            // One-shot on-upgrade Effort rescore (#313): recompute strain from source across the FULL
            // history once, so any deep-history rows an older build left on the 0–21 axis regenerate on
            // the 0–100 axis. Guarded by a persisted flag, so this is a no-op on every subsequent launch.
            await self.intelligence.runEffortRescoreIfNeeded()
            while !Task.isCancelled {
                await self.intelligence.analyzeRecent()
                // v5: recompute the skin-temp suite snapshots (cycle phase + body clock) from the
                // freshly-scored history so the Health hub cards read a ready result.
                await self.refreshV5Signals()
                try? await Task.sleep(nanoseconds: 900_000_000_000)  // 15 min, matches the offload cadence
            }
        }
    }

    /// Build the device registry + source coordinator once the store is open, then start observing.
    /// Tiny and guarded: with no generic strap paired the active id is "my-whoop", so the coordinator
    /// observes WHOOP-active and stays a NO-OP — the existing `scan()`/`disconnect()` WHOOP flow is
    /// untouched. The coordinator only acts if/when a non-WHOOP strap becomes the active device.
    /// `startWhoop`/`stopWhoop` are thin closures over BLEManager's EXISTING public methods (via the
    /// model's `scan()` / `disconnect()`), so the coordinator never references BLEManager directly.
    private func wireSourceCoordinator() async {
        guard sourceCoordinator == nil, let store = await repo.storeHandle() else { return }
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryQueue))
        registry.reload()
        let coordinator = SourceCoordinator(
            registry: registry,
            live: live,
            storeHandle: { [weak self] in await self?.repo.storeHandle() },
            startWhoop: { [weak self] in self?.scan() },
            stopWhoop: { [weak self] in self?.disconnect() },
            // WHOOP targeting hooks — thin wrappers over BLEManager's existing additive setters, so the
            // coordinator never references BLEManager directly (mirrors the start/stop injection). On the
            // single-WHOOP path these are setPreferredPeripheral(nil) and (no setActiveDeviceId call),
            // i.e. the BLE engine's defaults — no behaviour change.
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
    }

    private func refreshAfterCompletedBackfill() async {
        live.append(log: "Backfill: refreshing dashboard cache from completed sync")
        await repo.refresh(days: 120)
        // Score the freshly-offloaded raw data RIGHT NOW rather than waiting for the next 15-minute
        // analyzeRecent tick — otherwise a just-synced night's Charge / Effort / Rest can take up to
        // 15 minutes to appear on a strap-only (no-import) dashboard. analyzeRecent no-ops if a tick is
        // already running and refreshes the dashboard itself once the new scores persist. (PR #218)
        await intelligence.analyzeRecent()
        await refreshV5Signals()
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
            // median so screens that now prefer `bpm` fall through to "—" instead of freezing on the
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
        // heartRate AND rr update (~1–3 Hz), but the median is stable across most of them — an
        // unconditional assign re-renders every bpm observer (Live, menu bar, widgets) for nothing.
        let smoothed = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
        if bpm != smoothed { bpm = smoothed }
        captureWorkoutSample()
        evaluateStress()
    }

    // MARK: - Manual workout tracking

    /// Begin a manually-tracked workout. The active card on Live then shows elapsed time, live HR and
    /// strain building; End scores + saves it. Confirms with a single buzz.
    func startWorkout() {
        guard activeWorkout == nil else { return }
        lastWorkout = nil
        activeWorkout = ActiveWorkout(start: Date())
        buzz(loops: 1)
    }

    /// Finish the active workout: score the captured HR window and save it as a `WorkoutRow`. A session
    /// with too few samples (never streamed HR) is discarded quietly. Double-buzz confirms the save.
    func endWorkout() {
        guard let w = activeWorkout else { return }
        activeWorkout = nil
        let samples = w.samples
        guard samples.count >= 2 else { lastWorkout = nil; return }
        let end = Date()
        let avg = Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
        let peak = samples.map(\.bpm).max() ?? 0
        let strain = StrainScorer.strain(samples, maxHR: Double(profile.hrMax), sex: profile.sex)
        // Estimate calories from the captured HR window (same Keytel/Harris–Benedict model the
        // auto-detector uses) so a manual session shows energy too, not just duration/strain. (#117)
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let kcal = Calories.estimateBoutCalories(samples, profile: up, hrmax: Double(profile.hrMax), restingHR: nil).0
        let row = WorkoutRow(
            startTs: Int(w.start.timeIntervalSince1970), endTs: Int(end.timeIntervalSince1970),
            sport: "Workout", source: "manual", durationS: end.timeIntervalSince(w.start),
            energyKcal: kcal > 0 ? kcal : nil, avgHr: avg, maxHr: peak, strain: strain,
            distanceM: nil, zonesJSON: nil, notes: nil)
        lastWorkout = row
        buzz(loops: 2)
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
    }

    /// Drop the smoothing window and blank the hero number so a resume / re-attach shows "—"
    /// until a genuinely fresh sample arrives, instead of republishing the stale pre-gap median.
    /// Called on Live-tab entry / manual Start HR (see `startRealtimeHR`), NOT on the 30s keep-alive
    /// re-arm — so steady-state smoothing is untouched. Fixes #46 (HR jumped to a stale ~100 on
    /// reopen, then "slowly came back down" as fresh low samples refilled the window).
    func resetSmoothing() {
        hrWindow.removeAll()
        bpm = nil
    }

    /// Stress evaluation, two independent layers (each opt-in, each off by default):
    ///   • the legacy experimental `behavior.stressNudge` buzz (a fresh HRV dip → one confirming buzz);
    ///   • the v5 L3 closed-loop check-in — the unit-tested `StressOnsetDetector` decides, at the moment
    ///     it matters, whether to offer a 60-s guided breath. On a fresh, non-metabolic HRV dip while the
    ///     user is still it fires a single confirming buzz AND posts a passive nudge to `stressNudgeCenter`
    ///     (the dismissible Stress check-in card surfaces it). The detector carries its own replay-safe
    ///     state (de-dup + slow baseline + rate limit), persisted via `BiofeedbackPrefs` so a relaunch
    ///     can't re-fire. Honest / non-clinical: "stress" is an autonomic proxy vs the user's own
    ///     baseline, never a diagnosis.
    private func evaluateStress() {
        let fresh = live.rr.filter { $0 > 300 && $0 < 2000 }   // plausible R-R (30–200 bpm)
        guard !fresh.isEmpty else { return }
        rrBuf.append(contentsOf: fresh)
        if rrBuf.count > 120 { rrBuf.removeFirst(rrBuf.count - 120) }

        // ── Legacy experimental nudge (behavior.stressNudge) — unchanged behaviour, kept separate.
        if behavior.stressNudge, live.bonded, live.worn, rrBuf.count >= 20 {
            let rmssd = AppModel.rmssd(Array(rrBuf.suffix(60)))
            if rmssd > 0 {
                hrvBaseline = hrvBaseline == 0 ? rmssd : hrvBaseline * 0.98 + rmssd * 0.02   // slow EMA
                if let hr = bpm, hr >= 55, hr <= 100 {            // resting band — not a workout
                    let now = Date()
                    if rmssd < hrvBaseline * 0.6, now.timeIntervalSince(lastStressBuzzAt) > 900 {
                        lastStressBuzzAt = now
                        buzz(loops: 1)
                        live.append(log: "Stress nudge — take a paced breath")
                    }
                }
            }
        }

        // ── v5 L3 closed-loop check-in (StressOnsetDetector). Inert unless the master toggle is on; the
        // engine itself owns every gate (auto-nudge, exercise gate, quiet hours, rate limit, edge).
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
        live.append(log: "Stress check-in — HRV dipped while still")
    }

    /// Whether the encrypted channel is up so a confirming buzz can actually fire (the command
    /// characteristic is gated on bond; an un-encrypted live-HR-only link can't buzz).
    private var canBuzz: Bool { live.bonded && live.encryptedBond }

    static func rmssd(_ rr: [Int]) -> Double {
        guard rr.count >= 2 else { return 0 }
        var sum = 0.0, n = 0
        for i in 1..<rr.count { let d = Double(rr[i] - rr[i - 1]); sum += d * d; n += 1 }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }

    /// Start scanning for the strap. When no model is given, use the one the user
    /// picked (persisted under "selectedWhoopModel"), so every scan entry point —
    /// Live, onboarding, the menu bar, Settings — honours the same choice.
    func scan(model: WhoopModel? = nil) {
        let chosen = model
            ?? UserDefaults.standard.string(forKey: "selectedWhoopModel").flatMap(WhoopModel.init(rawValue:))
            ?? .whoop4
        ble.connect(model: chosen)
    }
    func disconnect() { ble.disconnect() }

    /// Drop the current strap and clear bond state so a newly-picked strap model connects fresh
    /// (lets a user with both a WHOOP 4 and a 5/MG switch between them).
    func prepareStrapSwitch() { ble.prepareForModelSwitch() }

    // MARK: - Add-a-device wizard (WHOOP present-scan + register/activate)
    //
    // Thin pass-throughs over BLEManager's EXISTING public present-scan surface so the wizard never
    // references BLEManager directly (mirrors `scan()` / `disconnect()`). The wizard observes
    // `ble.discoveredWhoops` for the WHOOP families and runs its own `StandardHRSource` for generic
    // straps — see AddDeviceWizard.

    /// The straps surfaced by the WHOOP present-scan (`scanForWhoops`), for the wizard's live list.
    /// Empty until a present-scan has discovered something; refreshed in place as RSSI updates.
    var discoveredWhoops: [(uuid: String, name: String, rssi: Int)] { ble.discoveredWhoops }

    /// Point the WHOOP scan at a specific family, then present nearby straps WITHOUT auto-connecting.
    /// `prepareForModelSwitch()` first clears any sticky bond/connection so the engine is idle, then
    /// `connect(model:)` selects the family + installs its framing (it sets the engine's private
    /// `selectedModel`, which `scanForWhoops()` scans for), and the immediate `scanForWhoops()` takes
    /// over the central in present-mode (it `stopScan()`s the connect's scan and re-arms a duplicate-
    /// allowing present scan). The persisted `selectedWhoopModel` is updated too, so a later real
    /// connect to the chosen strap targets the right family. All via existing public methods.
    func presentWhoopScan(model: WhoopModel) {
        UserDefaults.standard.set(model.rawValue, forKey: "selectedWhoopModel")
        ble.prepareForModelSwitch()           // idle the engine + clear sticky bond
        ble.connect(model: model)             // select the family (sets engine selectedModel + framing)
        ble.scanForWhoops()                   // take over the central, present nearby straps only
    }

    /// End the WHOOP present-scan (idempotent). Call on leaving the wizard's pick step / on dismiss.
    func stopWhoopScan() { ble.stopWhoopScan() }

    /// Register a paired device and (optionally) make it the active one. The Add-a-device wizard's
    /// single write path: `add` upserts the row, and when `makeActive` is true `setActive` promotes it
    /// (the SourceCoordinator reacts to the active-device change and connects). No-op if the registry
    /// hasn't been wired yet (pre store-open) — the wizard is only reachable once it has.
    func registerDevice(_ device: PairedDevice, makeActive: Bool) {
        guard let registry = deviceRegistry else { return }
        registry.add(device)
        if makeActive { registry.setActive(device.id) }
    }

    /// Enable the realtime stream + mark it wanted so the keep-alive re-arms it (can't lapse).
    /// Blanks the stale smoothing window first (#46): on Live-tab entry / resume we don't want the
    /// pre-gap median republished, so the hero shows "—" until a fresh sample lands. The keep-alive
    /// re-arm goes through `ble.startRealtime()` directly, NOT here, so steady-state is untouched.
    func startRealtimeHR() {
        resetSmoothing()
        ble.startRealtime()
    }
    /// Stop the realtime stream (the lightweight 0x2A37 HR keeps recording regardless).
    func stopRealtimeHR() { ble.stopRealtime() }
    /// Ask the strap for a fresh battery reading.
    func getBattery() { ble.refreshBattery() }

    /// Fire a haptic buzz on the strap. patternId=2 is the graduated buzz confirmed on-device;
    /// `loops` sets the length. Used by the in-app test button and (later) notification alerts.
    /// Requires a bonded connection — no-op otherwise (the command characteristic is gated on bond).
    func buzz(loops: UInt8 = 2) {
        ble.send(.runHapticsPattern, payload: [2, loops, 0, 0, 0])
    }

    /// Fire a specific preset haptic pattern (patternId 0–6 on Harvard; loops sets length).
    /// Used by the notification-pattern picker and coaching features.
    func buzz(pattern: UInt8, loops: UInt8 = 1) {
        ble.send(.runHapticsPattern, payload: [pattern, loops, 0, 0, 0])
    }

    /// Arm (or clear) the strap's firmware alarm from the smart-alarm settings. The firmware alarm
    /// fires even if the Mac is asleep / NOOP is closed. No-op until bonded (send is gated on bond).
    func applySmartAlarm() {
        guard behavior.smartAlarmEnabled else { ble.disableStrapAlarm(); return }
        let cal = Calendar.current
        let now = Date()
        var next = cal.date(bySettingHour: behavior.smartAlarmMinutes / 60,
                            minute: behavior.smartAlarmMinutes % 60, second: 0, of: now) ?? now
        if next <= now { next = cal.date(byAdding: .day, value: 1, to: next) ?? next }
        ble.armStrapAlarm(at: next)
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
                MacActions.runShortcut("Lock Screen")   // login.framework unavailable — fall back to a Shortcut
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

    /// Whether the user's locale formats time on a 24-hour clock — drives the Haptic Clock's hour
    /// encoding (#460) so a double-tap buzzes the time the way the user reads it. Derived from the
    /// locale's "j" (hour) template: a 12-hour locale includes the AM/PM ("a") symbol.
    static var localeUses24HourClock: Bool {
        let fmt = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h"
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

    /// #461: record a "sleep mark" — a bedtime / wake / mid-night tap. Stored like moments (survives
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
        let maxHR = Double(profile.hrMax)
        guard maxHR > 0 else { return }
        let pct = Double(hr) / maxHR
        let zone = pct >= 0.9 ? 5 : pct >= 0.8 ? 4 : pct >= 0.7 ? 3 : pct >= 0.6 ? 2 : 1
        defer { lastCoachZone = zone }
        guard lastCoachZone != -1, zone != lastCoachZone else { return }
        if zone == 5, lastCoachZone < 5 { buzz(loops: 3) }          // entered max — ease off
        else if zone <= 1, lastCoachZone > 1 { buzz(loops: 1) }     // recovered
    }

    /// Illness/strain early-warning (v5): the confounder-suppressed `IllnessSignalEngine`. For the last
    /// ~2 days vs a ~28-day personal baseline it z-scores resting HR, skin-temp deviation, HRV (negated)
    /// and respiration ORIENTED illness-ward, then the engine applies its minimum-corroboration gate,
    /// composite score, and — the differentiating part — same-day journal confounder suppression
    /// (alcohol / a hard-or-late workout / etc.) so a night out doesn't cry wolf. The journal context is
    /// read asynchronously, so this kicks a Task; the published `illnessSignal` + the `healthAlert`
    /// banner both come from the engine's single decision. On-device only, APPROXIMATE — not a diagnosis.
    private func evaluateIllness(_ days: [DailyMetric]) {
        guard behavior.illnessWatch, days.count >= 14 else {
            healthAlert = nil; illnessSignal = nil; return
        }
        Task { [weak self] in
            guard let self else { return }
            // Confounder tags from the recent journal (within the last ~2 days). Read once, off the
            // engine's hot path — the engine only needs presence flags, not the rows.
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

    /// Re-run the illness watch over the cached history. Called when the Automations toggle
    /// flips — the repo.$days sink only fires on data changes, so a flip would otherwise wait
    /// for the next refresh.
    func reevaluateIllness() {
        evaluateIllness(repo.days)
    }

    // MARK: - v5 skin-temp suite engines (cycle phase + body clock)
    //
    // Run in the analytics pass (IntelligenceEngine calls this after it persists the night's scores) so
    // the Health hub's skin-temp cards read a ready snapshot. Both are pure StrandAnalytics engines fed
    // from the merged daily history; cycle awareness is gated behind the opt-in flag (default OFF) and
    // never computes — let alone surfaces — until the user turns it on.

    /// UserDefaults key for the cycle-awareness opt-in (default OFF — the most sensitive health category,
    /// manual-first). The Settings toggle + the card's opt-in CTA both write this single key.
    static let cycleAwarenessKey = "noopCycleAwareness"
    var cycleAwarenessEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.cycleAwarenessKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.cycleAwarenessKey) }
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
        // the deviation against its own folded spread — a zero-centred personal baseline. RHR + HRV
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
        cyclePhase = CyclePhaseEngine.classify(nights, baselineUsable: skinState.usable)
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
    // touch the core resolvedSeries waterfall — it's an additive read that reuses the rows the store
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
        // IS the canonical source id, but the strap's real id is `deviceId`/`computed` — map explicitly.)
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
    /// A picked import file made safe to read. On iOS the security-scoped — and possibly
    /// iCloud-placeholder — URL is coordinated and COPIED into the app's temp directory, so the
    /// importer reads a stable LOCAL file. That's what makes import work for iCloud Drive files (they
    /// arrive as un-downloaded placeholders that ZIPFoundation can't open in place) and removes the
    /// scoped-access timing fragility that blocked iPhone imports (#179). On macOS the picked URL is
    /// read in place. `cleanup()` removes the temp copy. Sendable so it can cross the actor boundary.
    struct ImportFile: Sendable {
        let url: URL
        private let temp: URL?
        init(url: URL, temp: URL?) { self.url = url; self.temp = temp }
        func cleanup() { if let temp { try? FileManager.default.removeItem(at: temp) } }
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
        return ImportFile(url: dst, temp: dst)
        #else
        return ImportFile(url: picked, temp: nil)
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
                let summary = try await WhoopImporter.importExport(url: local.url, into: store, deviceId: deviceId)
                await repo.refresh()
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))–\(f.string(from: b))"
                } else { span = "" }
                finishImport(.whoop, summary: "Imported \(summary.recordCount) records\(span)")
            } catch {
                finishImport(.whoop, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    /// Import an Apple Health export (export.zip) — streams + aggregates per-day into the store
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
                let summary = try await XiaomiImporter.importExport(url: local.url, into: store)
                await repo.refresh()
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))–\(f.string(from: b))"
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
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.appleHealth, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                let summary = try await AppleHealthImport.importExport(url: local.url, into: store, deviceId: appleDeviceId)
                await repo.refresh()
                finishImport(.appleHealth, summary: "Imported \(summary.recordCount) records")
            } catch {
                finishImport(.appleHealth, summary: "Import failed: \(error)", failed: true)
            }
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
