package com.noop.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.noop.NoopApplication
import com.noop.analytics.IllnessWatch
import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.RouteMath
import com.noop.analytics.Sport
import com.noop.analytics.StrainScorer
import com.noop.analytics.UserProfile
import com.noop.analytics.WorkoutSport
import com.noop.location.LocationTracker
import kotlinx.coroutines.Job
import com.noop.ble.LiveState
import com.noop.ble.WhoopConnectionService
import com.noop.ble.WhoopModel
import androidx.health.connect.client.HealthConnectClient
import com.noop.data.DailyMetric
import com.noop.data.HrSample
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ingest.HealthConnectImporter
import com.noop.ingest.HealthConnectWriter
import com.noop.notif.IllnessAlertNotifier
import com.noop.protocol.CommandNumber
import com.noop.widget.WidgetSnapshot
import com.noop.widget.WidgetSnapshotStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

/**
 * The single app-wide view model. Holds the BLE client and the Room-backed
 * repository, re-publishes the BLE [LiveState], maintains a spike-filtered/smoothed
 * BPM for the big read-outs, and runs the on-device illness watch over cached
 * daily metrics. Mirrors the macOS AppModel responsibilities (LiveState bridge,
 * `bpm` smoothing, health-alert string) without any networking.
 */
class AppViewModel(app: Application) : AndroidViewModel(app) {

    /** Process-wide context for prefs + the background-connection service. */
    private val appContext = app.applicationContext

    /** The process owns the store + BLE client (see [NoopApplication]) so the connection can outlive
     *  this Activity-scoped ViewModel and keep streaming under [WhoopConnectionService]. */
    private val noopApp = app as NoopApplication

    // Offline store — process-wide, shared with the background service.
    private val repository: WhoopRepository = noopApp.repository

    // BLE client — process-owned; emits LiveState and persists decoded live + historical streams
    // into [repository] (same process-wide DB).
    val ble = noopApp.ble

    val repo: WhoopRepository get() = repository

    // Body profile (age/sex/weight/height + HR-max override) — the same SharedPreferences
    // store the Settings screen edits. Feeds the on-device scorer's HRmax/zones/calories.
    private val profileStore = ProfileStore.from(app.applicationContext)

    /** The imported strap source id (raw streams + imported history live under this). */
    private val deviceId = "my-whoop"

    /** Live connection + biometric snapshot, surfaced straight from the BLE client. */
    val live: StateFlow<LiveState> = ble.state

    /** Which strap the user is pairing — drives the scan filter in [connect]. Defaults to WHOOP 4.0. */
    private val _selectedModel = MutableStateFlow(WhoopModel.WHOOP4)
    val selectedModel: StateFlow<WhoopModel> = _selectedModel.asStateFlow()
    fun setSelectedModel(model: WhoopModel) {
        if (model == _selectedModel.value) return
        _selectedModel.value = model
        // Switching straps: forget the saved one so launch auto-reconnect (#67) doesn't target the old strap.
        NoopPrefs.clearLastDevice(appContext)
        // Drop the previous strap's sticky bond/connection so the next scan targets the new family's
        // service and bonds it fresh (lets a user move between a WHOOP 4 and a 5/MG).
        ble.prepareForModelSwitch()
    }

    // MARK: - Smoothed BPM (median over a short window, mirrors AppModel.bpm)

    private val hrWindow = ArrayDeque<Int>()
    private val hrWindowSize = 5
    private val _bpm = MutableStateFlow<Int?>(null)
    /** Spike-filtered, smoothed heart rate for the hero number. Null until data arrives. */
    val bpm: StateFlow<Int?> = _bpm.asStateFlow()

    // MARK: - Illness watch banner

    private val _healthAlert = MutableStateFlow<String?>(null)
    /** Non-null when the illness watch flags an early-warning pattern. Drives the banner. */
    val healthAlert: StateFlow<String?> = _healthAlert.asStateFlow()

    // Declared BEFORE the init block on purpose: the recentDays collector launched from init
    // runs synchronously on Main.immediate and reads this on its very first (cached) emission —
    // a declaration after init would still be null there (JVM initializes fields in declaration
    // order) and crash the constructor. Opt-OUT, default ON (Android has always run the watch);
    // port of macOS behavior.illnessWatch, which is opt-in.
    private val _illnessWatchEnabled = MutableStateFlow(NoopPrefs.illnessWatch(appContext))
    /** Whether the illness early-warning runs (banner + notification). */
    val illnessWatchEnabled: StateFlow<Boolean> = _illnessWatchEnabled.asStateFlow()

    // Declared BEFORE the init block for the SAME reason as _illnessWatchEnabled above: the bond
    // collector launched from init runs synchronously on Main.immediate and reads _smartAlarmEnabled on
    // its first (cached) emission. A declaration after init is null there and NPEs the constructor on a
    // cold start where the strap is already bonded — the #84 "crashes once, fine on the retry" race on
    // fast devices (S24+). Port of macOS BehaviorStore (Swift two-phase init makes this safe for free).
    private val _smartAlarmEnabled = MutableStateFlow(NoopPrefs.smartAlarmEnabled(appContext))
    val smartAlarmEnabled: StateFlow<Boolean> = _smartAlarmEnabled.asStateFlow()
    private val _smartAlarmMinutes = MutableStateFlow(NoopPrefs.smartAlarmMinutes(appContext))
    val smartAlarmMinutes: StateFlow<Int> = _smartAlarmMinutes.asStateFlow()

    // MARK: - Today's cached metrics

    private val _today = MutableStateFlow<DailyMetric?>(null)
    val today: StateFlow<DailyMetric?> = _today.asStateFlow()

    /**
     * Recent daily metrics (newest last), backing the Today grid + illness watch.
     * MERGED: imported "my-whoop" rows win per day; on-device computed "my-whoop-noop"
     * rows (from [IntelligenceEngine]) gap-fill, so recovery/strain/sleep populate from
     * the strap with no WHOOP import.
     */
    val recentDays: StateFlow<List<DailyMetric>> =
        repository.daysMergedFlow(deviceId)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    init {
        // Smooth HR from each LiveState emission, and re-arm the strap's firmware alarm whenever it
        // (re)bonds. A smart-alarm time changed while the strap was away never reached it — the send
        // is gated on bond — so the strap kept the OLD time and fired at it (#59). Gated on enabled so
        // a disabled alarm doesn't disarm on every reconnect.
        viewModelScope.launch {
            var lastBonded = false
            ble.state.collect { state ->
                state.heartRate?.let { ingestHr(it) }
                if (state.bonded && !lastBonded) {
                    if (_smartAlarmEnabled.value) applySmartAlarm()
                    // Remember this strap so we can reconnect to it directly on the next launch (#67),
                    // e.g. after an APK update restarts the process.
                    ble.lastDeviceAddress?.let { NoopPrefs.setLastDevice(appContext, it, _selectedModel.value) }
                }
                lastBonded = state.bonded
            }
        }
        // Recompute the illness banner + today's row whenever cached days change.
        viewModelScope.launch {
            recentDays.collect { days ->
                // Only treat a row as "today" if its date is the phone's ACTUAL local calendar day.
                // Was days.lastOrNull() — the newest stored row regardless of date — so after importing
                // historical data the newest import (e.g. months old) showed as today's synthesis (#23).
                val todayKey = java.time.LocalDate.now().toString()   // ISO yyyy-MM-dd, local
                _today.value = days.lastOrNull { it.day == todayKey }
                val previousAlert = _healthAlert.value
                _healthAlert.value =
                    if (_illnessWatchEnabled.value) IllnessWatch.evaluate(days) else null
                // Banner transition (clear → raised) → real system notification; the notifier's
                // persisted day gate dedupes against the background-service call site.
                if (previousAlert == null) {
                    _healthAlert.value?.let { IllnessAlertNotifier.onEvaluated(appContext, it) }
                }
                // Keep the home-screen widget fresh while the app is open — covers users who turned
                // the background service off (the service is the widget's heartbeat otherwise).
                // Throttled + no-op without a placed widget; never let a Glance hiccup kill the collector.
                runCatching {
                    val live = ble.state.value
                    WidgetSnapshotStore.push(
                        appContext,
                        WidgetSnapshot(
                            recoveryPct = _today.value?.recovery?.roundToInt(),
                            heartRate = live.heartRate,
                            batteryPct = live.batteryPct?.roundToInt(),
                            connected = live.connected,
                            updatedAtMs = System.currentTimeMillis(),
                        ),
                    )
                }
            }
        }

        // Turn the strap's offloaded raw data into dashboard scores on launch and every
        // 15 minutes, so recovery / strain / sleep populate from the strap itself with no
        // import. IntelligenceEngine computes, persists under "my-whoop-noop", and the
        // merged daysMergedFlow above republishes the freshly computed scores to the UI.
        // Mirrors macOS AppModel's launch + 15-min analyze loop.
        viewModelScope.launch {
            delay(FIRST_OFFLOAD_GRACE_MS) // give the first offload a moment
            while (isActive) {
                runCatching {
                    IntelligenceEngine.analyzeRecent(
                        repo = repository,
                        profile = currentProfile(),
                        importedDeviceId = deviceId,
                        maxHROverride = profileStore.hrMaxOverride
                            .takeIf { it > 0 }?.toDouble(),
                    )
                }
                // Opt-in writeback: push the freshly computed nights into Health Connect so other
                // apps see them. Idempotent (clientRecordId per metric+day), so re-running every
                // cycle just upserts. Never let an HC hiccup (perm revoked mid-flight, provider
                // update) break the analysis loop.
                if (_hcWriteback.value) {
                    runCatching { HealthConnectWriter.write(appContext, repository) }
                }
                delay(ANALYZE_INTERVAL_MS) // 15 min, matches the offload cadence
            }
        }

        // Reconnect to the strap we last bonded to, so the user doesn't have to tap Connect after an
        // app update / restart (#67). Self-gates on the keep-connected pref + a saved strap + permission.
        autoReconnectOnLaunch()
    }

    /**
     * On launch, reconnect DIRECTLY to the strap we last bonded to (no scan), so the connection
     * survives an app update / restart without the user tapping Connect (#67). Gated on "Keep
     * connected in the background" (the user's keep-it-on intent) and a previously-bonded strap; the
     * BLE client itself no-ops if already connected or the runtime permission isn't granted yet.
     */
    private fun autoReconnectOnLaunch() {
        val saved = NoopPrefs.lastDevice(appContext) ?: return
        // Restore the model selection whenever a strap is remembered — deliberately NOT gated on the
        // background-connection pref, so an opted-out 5/MG user's picker and scan family still
        // survive restarts. Only the reconnect itself respects the pref. (#78 fork)
        _selectedModel.value = saved.second
        if (!NoopPrefs.backgroundConnection(appContext)) return
        ble.reconnectToAddress(saved.first, saved.second)
    }

    /** Snapshot the user's body profile from SharedPreferences as an analytics [UserProfile]. */
    private fun currentProfile(): UserProfile = UserProfile(
        weightKg = profileStore.weightKg,
        heightCm = profileStore.heightCm,
        age = profileStore.age.toDouble(),
        sex = profileStore.sex,
    )

    // MARK: - HR smoothing (median filter)

    private fun ingestHr(raw: Int) {
        if (raw <= 0) return
        hrWindow.addLast(raw)
        while (hrWindow.size > hrWindowSize) hrWindow.removeFirst()
        val sorted = hrWindow.sorted()
        _bpm.value = sorted[sorted.size / 2]
        captureWorkoutSample(_bpm.value!!)
    }

    // MARK: - Manual workout tracking
    //
    // Lets a user start/stop a workout themselves rather than relying on auto-detection (a top request).
    // Holds the start time + the live HR collected since; on End the window is scored via StrainScorer
    // and saved as a WorkoutRow (source "manual"), which then shows in the Workouts screen. The day's
    // strain already counts this HR (same live stream the store persists), so it's a per-session
    // annotation, not a double-count. Mirrors macOS AppModel.

    /** A manual workout in progress. [samples] accumulate from the smoothed live bpm; [liveStrain] is
     *  recomputed as the window grows so the active card shows strain building in real time. */
    data class ActiveWorkout(
        val startMs: Long,
        val sport: Sport,
        val gpsEnabled: Boolean,
        val samples: List<HrSample> = emptyList(),
        val track: List<RouteMath.LatLng> = emptyList(),
        val distanceM: Double = 0.0,
        val paceSecPerKm: Double? = null,
        val liveStrain: Double = 0.0,
        val avgHr: Int = 0,
        val peakHr: Int = 0,
    )

    private val _activeWorkout = MutableStateFlow<ActiveWorkout?>(null)
    val activeWorkout: StateFlow<ActiveWorkout?> = _activeWorkout.asStateFlow()
    private val _lastWorkout = MutableStateFlow<WorkoutRow?>(null)
    val lastWorkout: StateFlow<WorkoutRow?> = _lastWorkout.asStateFlow()

    private val locationTracker by lazy { LocationTracker(appContext) }
    private var gpsJob: Job? = null

    /** Begin a workout for [sport]; start GPS route tracking when [gpsEnabled]. Single buzz confirms. */
    fun startWorkout(sport: Sport = WorkoutSport.default, gpsEnabled: Boolean = false) {
        if (_activeWorkout.value != null) return
        _lastWorkout.value = null
        _activeWorkout.value = ActiveWorkout(startMs = System.currentTimeMillis(), sport = sport, gpsEnabled = gpsEnabled)
        buzz(1)
        if (gpsEnabled) {
            gpsJob = viewModelScope.launch {
                locationTracker.stream().collect { pt -> appendTrackPoint(pt) }
            }
        }
    }

    private fun appendTrackPoint(pt: RouteMath.LatLng) {
        val w = _activeWorkout.value ?: return
        val track = w.track + pt
        val dist = RouteMath.totalMeters(track)
        val secs = (System.currentTimeMillis() - w.startMs) / 1000.0
        _activeWorkout.value = w.copy(track = track, distanceM = dist, paceSecPerKm = RouteMath.paceSecPerKm(dist, secs))
    }

    /** Finish the active workout: score the captured HR window + finalize the GPS route, save a
     *  WorkoutRow, and (opt-in) write it to Health Connect. A session with no HR AND no track is
     *  discarded quietly. Double-buzz confirms the save. */
    fun endWorkout() {
        val w = _activeWorkout.value ?: return
        _activeWorkout.value = null
        gpsJob?.cancel(); gpsJob = null
        val samples = w.samples
        if (samples.size < 2 && w.track.size < 2) { _lastWorkout.value = null; return }
        val endMs = System.currentTimeMillis()
        val avg = if (samples.isNotEmpty()) samples.sumOf { it.bpm } / samples.size else null
        val peak = if (samples.isNotEmpty()) samples.maxOf { it.bpm } else null
        val strain = if (samples.size >= 2)
            StrainScorer.strain(samples, maxHR = profileStore.hrMax.toDouble(), sex = profileStore.sex) else null
        val row = WorkoutRow(
            deviceId = deviceId, startTs = w.startMs / 1000, endTs = endMs / 1000,
            sport = w.sport.name, source = "manual", durationS = (endMs - w.startMs) / 1000.0,
            avgHr = avg, maxHr = peak, strain = strain,
            distanceM = w.distanceM.takeIf { it > 0 },
            routePolyline = if (w.track.size >= 2) RouteMath.encode(w.track) else null,
        )
        _lastWorkout.value = row
        buzz(2)
        viewModelScope.launch {
            runCatching { repository.upsertWorkouts(listOf(row)) }
            if (_hcWriteback.value) {
                runCatching { HealthConnectWriter.writeExercise(appContext, row, w.sport.exerciseType) }
            }
        }
    }

    /** Append the current smoothed bpm to the active workout and recompute its running strain. Called
     *  from ingestHr on every fresh sample; a no-op when no workout is running. */
    private fun captureWorkoutSample(bpm: Int) {
        val w = _activeWorkout.value ?: return
        val s = w.samples + HrSample(deviceId = deviceId, ts = System.currentTimeMillis() / 1000, bpm = bpm)
        val strain = StrainScorer.strain(s, maxHR = profileStore.hrMax.toDouble(), sex = profileStore.sex) ?: 0.0
        _activeWorkout.value = w.copy(
            samples = s, avgHr = s.sumOf { it.bpm } / s.size, peakHr = s.maxOf { it.bpm }, liveStrain = strain,
        )
    }

    /**
     * Drop the smoothing window and blank the hero number so a resume / re-attach shows "—" until a
     * genuinely fresh sample arrives, instead of republishing the stale pre-gap median. Called on
     * Live/Health screen entry (requestRealtimeHr 0->1), NOT on keep-alive re-arm, so steady-state
     * smoothing is untouched. Mirrors AppModel.resetSmoothing and the existing disconnect() clear.
     * Fixes #46 (HR jumped to a stale ~100 on reopen, then settled as fresh low samples refilled).
     */
    private fun resetSmoothing() {
        hrWindow.clear()
        _bpm.value = null
    }

    // MARK: - Strap controls (thin pass-throughs to the BLE client)

    fun connect(promoteService: Boolean = true) {
        ble.connect(_selectedModel.value)
        // Keep the link alive when the app is closed, unless the user has opted out. Started from the
        // foreground (this is a user tap), so Android 12+'s background-start rule is satisfied.
        // Onboarding auto-connects before the user has finished setup and passes promoteService=false
        // so the persistent notification doesn't appear mid-flow; it promotes once on completion.
        if (promoteService && NoopPrefs.backgroundConnection(appContext)) {
            WhoopConnectionService.start(appContext)
        }
    }

    /** Promote the background service now if a strap is live and the user hasn't opted out — used by
     *  onboarding to defer the foreground notification until the flow completes. */
    fun promoteBackgroundConnectionIfActive() {
        if (!NoopPrefs.backgroundConnection(appContext)) return
        if (ble.state.value.connected || ble.state.value.bonded) {
            WhoopConnectionService.start(appContext)
        }
    }

    fun disconnect() {
        // User asked to disconnect: drop the foreground promotion first, then the link itself.
        WhoopConnectionService.stop(appContext)
        ble.disconnect()
        hrWindow.clear()
        _bpm.value = null
    }

    /**
     * Flip the "keep connected in the background" preference (driven by Settings). Turning it on
     * while a strap is live promotes to the foreground immediately; turning it off drops the
     * foreground service (the connection stays up until the app is actually closed).
     */
    fun setBackgroundConnection(enabled: Boolean) {
        NoopPrefs.setBackgroundConnection(appContext, enabled)
        if (enabled) {
            if (ble.state.value.connected || ble.state.value.bonded) {
                WhoopConnectionService.start(appContext)
            }
        } else {
            WhoopConnectionService.stop(appContext)
        }
    }

    /**
     * Flip "Debug logging" (driven by Settings → Strap). Persists the preference and pushes it to the
     * live BLE client so it takes effect immediately. Default OFF: the strap log stays in the in-app
     * ring buffer (and the "Share strap log" export) but is not mirrored to logcat unless the user opts
     * in — so a normal user never writes the connection log to the system log. With it on, developers
     * can watch the connection live over `adb logcat -s WhoopBleClient`.
     */
    fun setDebugLogging(enabled: Boolean) {
        NoopPrefs.setDebugLogging(appContext, enabled)
        ble.debugLogcat = enabled
    }

    // --- Health Connect periodic auto-sync (Samsung Health → Health Connect → NOOP) ---
    private val _hcAutoSync = MutableStateFlow(NoopPrefs.hcAutoSync(appContext))
    val hcAutoSync: StateFlow<Boolean> = _hcAutoSync.asStateFlow()
    private val _hcSyncHours = MutableStateFlow(NoopPrefs.hcSyncHours(appContext))
    val hcSyncHours: StateFlow<Int> = _hcSyncHours.asStateFlow()
    private val _hcLastSync = MutableStateFlow(NoopPrefs.hcLastSync(appContext))
    val hcLastSync: StateFlow<Long> = _hcLastSync.asStateFlow()
    private val _hcWriteback = MutableStateFlow(NoopPrefs.hcWriteback(appContext))
    val hcWriteback: StateFlow<Boolean> = _hcWriteback.asStateFlow()

    init {
        // On app open, catch up the Health Connect sync if it's overdue. This on-open import is the
        // ONLY auto-sync path: we deliberately skip a true-background worker — it needs a sensitive
        // background-health permission and is unreliable on Android 14+, and opening the app regularly
        // is enough for a personal health app.
        syncHealthConnectIfStale()
    }

    /** Flip auto-sync. Persists and, on enable, kicks an immediate import; thereafter it catches up on
     *  app open via [syncHealthConnectIfStale]. */
    fun setHcAutoSync(enabled: Boolean) {
        _hcAutoSync.value = enabled
        NoopPrefs.setHcAutoSync(appContext, enabled)
        if (enabled) syncHealthConnectIfStale(force = true)
    }

    /** Change the sync interval (hours). Takes effect on the next on-open catch-up sync. */
    fun setHcSyncHours(hours: Int) {
        _hcSyncHours.value = hours
        NoopPrefs.setHcSyncHours(appContext, hours)
    }

    /** Flip Health Connect writeback (computed metrics → HC). Persists; the UI requests the write
     *  permissions and kicks the first write via [writebackHealthConnectNow]. While on, every 15-min
     *  recompute re-writes (idempotent — clientRecordId upserts). Default OFF. */
    fun setHcWriteback(enabled: Boolean) {
        _hcWriteback.value = enabled
        NoopPrefs.setHcWriteback(appContext, enabled)
    }

    /** One immediate writeback (permissions assumed granted — the UI gates on that). */
    fun writebackHealthConnectNow() {
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                runCatching { HealthConnectWriter.write(appContext, repository) }
            }
        }
    }

    /**
     * Foreground catch-up import: when auto-sync is on and the last sync is older than the chosen
     * interval (or [force]), pull from Health Connect now. Health Connect background reads are
     * restricted, so opening the app is the guaranteed sync point. No-ops silently if Health Connect
     * is unavailable or its read permissions aren't granted (the UI requests them when enabling).
     */
    fun syncHealthConnectIfStale(force: Boolean = false) {
        if (!_hcAutoSync.value) return
        val intervalMs = _hcSyncHours.value.toLong() * 60 * 60 * 1000
        val last = _hcLastSync.value
        val now = System.currentTimeMillis()
        if (!force && last != 0L && now - last < intervalMs) return
        viewModelScope.launch {
            val ran = withContext(Dispatchers.IO) {
                if (HealthConnectImporter.sdkStatus(appContext) != HealthConnectClient.SDK_AVAILABLE) {
                    return@withContext false
                }
                val granted = runCatching {
                    HealthConnectImporter.client(appContext).permissionController.getGrantedPermissions()
                }.getOrDefault(emptySet())
                if (!granted.containsAll(HealthConnectImporter.PERMISSIONS)) return@withContext false
                runCatching { HealthConnectImporter.import(appContext, repository) }.isSuccess
            }
            if (ran) {
                val t = System.currentTimeMillis()
                NoopPrefs.setHcLastSync(appContext, t)
                _hcLastSync.value = t
            }
        }
    }

    /** How many screens currently want the live HR stream (Live, Health Monitor, …). The stream stays
     *  on while ANY of them is visible, so navigating between them doesn't stop it (issue #18: leaving
     *  Live sent TOGGLE_REALTIME_HR=0, leaving Health Monitor with a frozen value). */
    private var realtimeWanters = 0

    /** A screen that shows live HR appeared. Arms the realtime stream on the 0→1 transition, and
     *  blanks the stale smoothing window so a resume shows "—" until a fresh sample lands (#46).
     *  Guarded on 0→1 so a second concurrent HR screen doesn't re-clear an already-live window. */
    fun requestRealtimeHr() {
        if (realtimeWanters++ == 0) {
            resetSmoothing()
            ble.startRealtime()
        }
    }

    /** A live-HR screen went away. Stops the realtime stream only when the last one leaves. */
    fun releaseRealtimeHr() {
        realtimeWanters = (realtimeWanters - 1).coerceAtLeast(0)
        if (realtimeWanters == 0) ble.stopRealtime()
    }

    /** Refresh the battery reading. Reads the standard 0x2A19 characteristic (works on 5/MG, where the
     *  proprietary command is dropped) and also fires the legacy command on WHOOP 4. */
    fun getBattery() = ble.refreshBattery()

    // --- Smart alarm (persisted; arms the strap's firmware alarm). Port of macOS BehaviorStore +
    // AppModel.applySmartAlarm. The previous Android UI was a non-persisted mock-up (issue #51).
    // NOTE: the _smartAlarm* state fields are declared ABOVE the init block (next to _illnessWatchEnabled)
    // so the init bond-collector can't read them before they're initialized (#84). ---

    fun setSmartAlarmEnabled(enabled: Boolean) {
        _smartAlarmEnabled.value = enabled
        NoopPrefs.setSmartAlarmEnabled(appContext, enabled)
        applySmartAlarm()
    }

    fun setSmartAlarmMinutes(minutes: Int) {
        _smartAlarmMinutes.value = minutes.coerceIn(0, 24 * 60 - 1)
        NoopPrefs.setSmartAlarmMinutes(appContext, _smartAlarmMinutes.value)
        applySmartAlarm()
    }

    // --- Illness watch (opt-out; the evaluation itself is the pure IllnessWatch.evaluate).
    // State lives next to _healthAlert above (declaration-order constraint); setter here with
    // the other settings mutators. ---
    fun setIllnessWatchEnabled(enabled: Boolean) {
        _illnessWatchEnabled.value = enabled
        NoopPrefs.setIllnessWatch(appContext, enabled)
        // Recompute now — the recentDays collector only fires on data changes.
        _healthAlert.value = if (enabled) IllnessWatch.evaluate(recentDays.value) else null
    }

    /** Arm or clear the strap's firmware alarm from the current setting, computing the next occurrence
     *  of the wake time (today, or tomorrow if it's already passed). Needs the strap connected — if it
     *  isn't, `send()` logs "ignored — not connected" and arming happens next time you connect + toggle. */
    private fun applySmartAlarm() {
        if (!_smartAlarmEnabled.value) {
            ble.disableStrapAlarm()
            return
        }
        val cal = java.util.Calendar.getInstance().apply {
            set(java.util.Calendar.HOUR_OF_DAY, _smartAlarmMinutes.value / 60)
            set(java.util.Calendar.MINUTE, _smartAlarmMinutes.value % 60)
            set(java.util.Calendar.SECOND, 0)
            set(java.util.Calendar.MILLISECOND, 0)
        }
        if (cal.timeInMillis <= System.currentTimeMillis()) cal.add(java.util.Calendar.DAY_OF_YEAR, 1)
        ble.armStrapAlarm(cal.timeInMillis / 1000)
    }

    /** Fire a haptic buzz on the strap (requires a bonded connection). */
    fun buzz(loops: Int = 2) = ble.buzz(loops)

    override fun onCleared() {
        super.onCleared()
        // The BLE client is process-owned (NoopApplication) and may be held up by
        // WhoopConnectionService, so we never shut it down here. Only drop the connection when the
        // user hasn't opted into background streaming — otherwise closing the UI would defeat the
        // foreground service. (We deliberately do NOT call ble.shutdown(): the client outlives the
        // ViewModel and is reused by the next Activity.)
        if (!NoopPrefs.backgroundConnection(appContext)) {
            ble.disconnect()
        }
    }

    private companion object {
        /** Grace before the first scoring pass, letting the first BLE offload land. */
        const val FIRST_OFFLOAD_GRACE_MS = 6_000L
        /** On-device scoring cadence — 15 min, matching the strap offload cadence. */
        const val ANALYZE_INTERVAL_MS = 15 * 60 * 1_000L
    }
}
