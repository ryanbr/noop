package com.noop.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.noop.NoopApplication
import com.noop.R
import com.noop.alarm.SleepWindowWatcher
import com.noop.alarm.SmartAlarmScheduler
import com.noop.alarm.SmartAlarmStore
import com.noop.analytics.BatteryEstimator
import com.noop.analytics.IllnessWatch
import com.noop.analytics.RestScorer
import com.noop.data.DailyMetric
import com.noop.location.GpsSession
import com.noop.location.LocationTracker
import com.noop.notif.BatteryAlertNotifier
import com.noop.notif.IllnessAlertNotifier
import com.noop.ui.NoopPrefs
import com.noop.ui.appLaunchIntent
import com.noop.widget.WidgetSnapshot
import com.noop.widget.WidgetSnapshotStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Foreground service that keeps the WHOOP BLE connection alive while the app is backgrounded or
 * closed.
 *
 * Android tears a process down shortly after its last Activity goes away, which is exactly why
 * people on Reddit saw the strap disconnect the moment they closed NOOP. A started foreground
 * service — with an ongoing notification — keeps the process (and therefore the
 * [com.noop.NoopApplication]-owned [WhoopBleClient] and its GATT link) resident, so heart rate
 * keeps streaming and offloads keep landing in the background.
 *
 * It does **not** own or drive the connection: it simply holds the process up and mirrors the
 * client's [LiveState] into the notification. Start/stop is gated by a Settings toggle (see
 * `NoopPrefs.backgroundConnection`) and only ever happens from the foreground (on connect / when
 * the user flips the toggle), so we never trip Android 12+'s background-start restriction.
 *
 * The matching capability on macOS is free: `AppModel` is an app-level `@StateObject` kept alive by
 * the menu-bar extra, so closing the window leaves the strap connected.
 */
/**
 * One tick of the ongoing-notification/widget stream. [dayState] is memoized separately from the
 * ~1 Hz [LiveState] so daily analytics are not recomputed for every heart-rate sample.
 */
private data class NotifyTick(
    val state: LiveState,
    val dayState: NotifyDayState,
)

/**
 * Daily values consumed by the foreground-service collector. Carries TWO recovery projections on
 * purpose (#911): [todayRecovery] is the honest-null notification value, while [widgetRecovery] is
 * the carried widget anchor. [days] stays by reference for the battery night-guard, which reads it
 * only when the strap's battery percentage changes.
 */
internal data class NotifyDayState(
    val todayRecovery: Double?,
    val widgetRecovery: Int?,
    val widgetRest: Int?,
    val widgetEffort: Int?,
    val illness: String?,
    val days: List<DailyMetric>,
)

/**
 * Memoizes daily-row selection and Illness Watch evaluation across live-state emissions.
 *
 * `combine` reuses the exact immutable day-list instance until the Room flow emits again, while BLE
 * state can emit about once per second. Identity is therefore the cheap generation token: a new list,
 * a logical/local-day rollover, or an Illness Watch preference change refreshes the projection. This
 * preserves the old behavior at midnight/04:00 and when the opt-out changes without rescanning up to
 * 800 day rows or allocating Illness Watch slices for every heart-rate sample.
 */
internal class NotifyDayStateCache(
    private val illnessEvaluator: (List<DailyMetric>) -> String? = IllnessWatch::evaluate,
) {
    private var cachedDays: List<DailyMetric>? = null
    private var cachedLogicalKey: String? = null
    private var cachedLocalKey: String? = null
    private var cachedIllnessEnabled: Boolean? = null
    private var cachedState: NotifyDayState? = null

    fun resolve(
        days: List<DailyMetric>,
        logicalKey: String,
        localKey: String,
        illnessEnabled: Boolean,
    ): NotifyDayState {
        cachedState?.let { state ->
            if (days === cachedDays && logicalKey == cachedLogicalKey && localKey == cachedLocalKey &&
                illnessEnabled == cachedIllnessEnabled
            ) {
                return state
            }
        }

        val todayRow = com.noop.ui.resolveTodayRow(days, logicalKey, localKey)
        val anchorRow = com.noop.ui.widgetAnchorRow(days, logicalKey, localKey)
        val state = NotifyDayState(
            todayRecovery = todayRow?.recovery,
            widgetRecovery = anchorRow?.recovery?.roundToInt(),
            widgetRest = anchorRow?.let { RestScorer.restFromDaily(it)?.roundToInt() },
            widgetEffort = anchorRow?.strain?.roundToInt(),
            illness = if (illnessEnabled) illnessEvaluator(days) else null,
            days = days,
        )
        cachedDays = days
        cachedLogicalKey = logicalKey
        cachedLocalKey = localKey
        cachedIllnessEnabled = illnessEnabled
        cachedState = state
        return state
    }
}

class WhoopConnectionService : Service() {

    /** Main-thread scope used only to mirror [LiveState] into the notification. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** The single live-state→notification collector. Re-`start`s land here repeatedly (on every
     *  connect, plus any OS restart), so we cancel the old one before launching a new one. */
    private var notifyJob: Job? = null

    /** Daily analytics projection shared across the notification's ~1 Hz live-state ticks. */
    private val notifyDayStateCache = NotifyDayStateCache()

    /** Watches [GpsSession] and runs the platform location stream while a GPS workout is active. This
     *  is what makes route tracking survive the screen turning off (#215): the collection lives on the
     *  always-on service, not the Activity-scoped ViewModel that Android cancels when it's cleared. */
    private var gpsGateJob: Job? = null

    /** The actual location collector, alive only while a GPS workout is in flight. Cancelled (which
     *  removes the LocationManager updates via the stream's awaitClose) the moment the workout ends. */
    private var gpsJob: Job? = null

    /** Platform-GPS wrapper (no Google Play Services). Lazily built — the service holds a Context. */
    private val locationTracker by lazy { LocationTracker(this) }

    /** Last illness-watch evaluation seen by the collector — clear→raised is the notify edge.
     *  In-memory on purpose: the persisted once-a-day gate (NoopPrefs) handles dedupe across
     *  process restarts and the AppViewModel call site. */
    private var lastIllnessAlert: String? = null

    /** Last battery % the predictive runtime alert was evaluated at. The live-state flow emits far
     *  more often than the strap's ~8-min battery cadence; gating the Room read + estimator fit on an
     *  actual SoC change keeps the predictive path as cheap as the SoC-only alert beside it. */
    private var lastRuntimeEvalPct: Int? = null

    /**
     * Last (SoC %, charging) pair the battery-alert policies were evaluated for, so they run on a CHANGE
     * rather than on every live-state emission.
     *
     * The collector below ticks at live-HR cadence (~1/s while connected). Both notifiers early-exit on
     * their own PERSISTED once-per-crossing gates, but not before each has done a SharedPreferences read,
     * a `NotificationManagerCompat.areNotificationsEnabled()` binder call and an `ensureChannel()` —
     * roughly two binder calls and half a dozen prefs reads every second, to re-answer a question the
     * strap only changes every ~8 minutes.
     *
     * Gated on the PAIR, not the percentage alone: [BatteryAlertNotifier.onBatteryUpdate] owns the
     * charge-complete and re-arm transitions, which key off `charging`. A user plugging in before the
     * percentage ticks would otherwise have their re-arm deferred by up to a battery-report cycle.
     */
    private var lastBatteryAlertKey: Pair<Int?, Boolean?>? = null

    /** The user's LEARNED habitual midsleep (local seconds-of-day), cached for the battery
     *  night-guard. null = cold start (< [com.noop.analytics.SleepStageTotals.HABITUAL_MIN_DAYS]
     *  nights), which is what makes `BatteryEstimator.bedtimeAlert` stay silent instead of testing
     *  against a fabricated bedtime. */
    private var habitualMidsleepCache: Int? = null

    /** Wall-clock ms of the last [refreshHabitualMidsleep] attempt; 0 = never. */
    private var habitualMidsleepCachedAtMs: Long = 0L

    /** Smart-alarm light-sleep watcher (#207). Feeds the live HR while we're inside the wake window
     *  and, on a lighter-phase reading, advances the GUARANTEED alarm earlier. It can only ever move
     *  the alarm earlier within the window — the hard deadline scheduled via AlarmManager is the floor
     *  of safety, so if BLE drops or no light sleep is found the user is still woken at the window end.
     *  The detector is reset each time we (re)enter a window. */
    private val sleepWatcher = SleepWindowWatcher()
    private var inAlarmWindow = false

    /** The smart-alarm HR collector, alive for the life of the service. */
    private var alarmJob: Job? = null

    private val ble get() = (application as NoopApplication).ble
    private val repo get() = (application as NoopApplication).repository

    /**
     * Watches the OS PAIRING flow (#1635). NOOP has never observed ACTION_BOND_STATE_CHANGED, so whether a
     * CLIENT_HELLO triggers pairing at all - and whether that pairing fails - has been invisible. A WHOOP
     * 5/MG shows every CLIENT_HELLO unacknowledged and the link torn down locally on a clockwork timer;
     * seeing BOND_NONE -> BOND_BONDING -> BOND_NONE across that window decides it, and seeing no transition
     * at all decides it the other way. Registered and unregistered alongside [bluetoothStateReceiver].
     */
    private val bondStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
            val dev: BluetoothDevice? = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            val cur = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
            val prev = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR)
            runCatching { ble.onBondStateChanged(prev, cur, dev?.address) }
        }
    }

    /**
     * Watches the OS Bluetooth radio so turning it off immediately tears down NOOP's orphaned GATT
     * link (#314). Without this there is no ACTION_STATE_CHANGED listener at all, so the radio going off
     * never reaches [WhoopBleClient] — the link stays "connected", the UI keeps showing live HR/buzz/sync
     * that isn't real, and the next write crashes on a dead binder (iOS/macOS are immune because
     * CoreBluetooth's send() is state-guarded). Registered while the FGS is alive (it is the long-lived
     * owner of the connection) and unregistered in [onDestroy]. STATE_TURNING_OFF/OFF → teardown +
     * connected=false; STATE_ON → resume the connection.
     */
    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                // Catch TURNING_OFF (the earliest signal) AND OFF — by TURNING_OFF the binder is already
                // on its way down, so tearing down here pre-empts the crash window.
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> ble.onBluetoothRadioOff()
                BluetoothAdapter.STATE_ON -> ble.onBluetoothRadioOn()
            }
        }
    }

    /** True once [bluetoothStateReceiver] and [bondStateReceiver] are registered, so repeat
     *  onStartCommands don't double-register (which would later throw on a single unregister). Both
     *  register together and unregister together, so one flag covers the pair. */
    private var bluetoothReceiverRegistered = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The notification "Disconnect" action routes back here as a self-intent.
        if (intent?.action == ACTION_STOP) {
            runCatching { ble.disconnect() }
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        ensureChannel()
        // Must call startForeground promptly after startForegroundService(). If it fails (e.g. the
        // API 34 connectedDevice type needs BLUETOOTH_CONNECT and the user denied it) we stop cleanly
        // rather than crash — the connection itself keeps working in the foreground regardless.
        if (!startForegroundCompat(buildNotification(ble.state.value, null))) {
            stopSelf()
            return START_NOT_STICKY
        }

        // Listen for the OS Bluetooth radio toggling so turning it off tears the link down at once (#314).
        // Guarded so repeat onStartCommands (every connect / OS restart) don't stack registrations.
        if (!bluetoothReceiverRegistered) {
            runCatching {
                ContextCompat.registerReceiver(
                    this,
                    bluetoothStateReceiver,
                    IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                    ContextCompat.RECEIVER_NOT_EXPORTED,
                )

                // #1635: same lifecycle and the same registration form as the radio receiver above - the FGS
                // owns the connection, so the pairing flow is only interesting while it is alive, and both are
                // torn down together in onDestroy.
                ContextCompat.registerReceiver(
                    this,
                    bondStateReceiver,
                    IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),
                    ContextCompat.RECEIVER_NOT_EXPORTED,
                )
            }.onSuccess { bluetoothReceiverRegistered = true }
        }

        // Keep the ongoing notification in step with the live connection state AND today's recovery
        // (the 15-min IntelligenceEngine recompute), so it re-posts when either changes — a glanceable
        // poor-man's Live Activity (#42). daysMergedFlow is the same merged store the dashboard reads.
        notifyJob?.cancel()
        notifyJob = scope.launch {
            combine(
                ble.state,
                // Defence-in-depth: a Room/disk error in this flow would otherwise propagate uncaught
                // out of scope.launch and kill the process — the FGS exists to protect the connection,
                // not to take it down. (Audited during #82, which proved unrelated/unreproducible —
                // this guard is belt-and-braces, not a diagnosed fix.) After catch{emit} the inner
                // flow completes; combine keeps running on ble.state with days frozen.
                // #797: the bounded merge (recentDaysMergedFlow) is enough here, the notification only reads
                // today's row; this stops a years-deep import re-merging the whole history on every change.
                // #1304/#512: the active strap's live day is under its own id ("whoop-<uuid>"); a raw
                // "my-whoop" read (which the union method collapses to) misses it. Same accessor as :606.
                repo.recentDaysMergedFlow((application as NoopApplication).activeDeviceId).catch { emit(emptyList()) },
            ) { state, days ->
                // #911: resolve the day the way the dashboard does, via the LOGICAL local day (rolls at
                // 04:00, with the #304 pre-04:00 carve-out), NOT a naive LocalDate.now() that rolls at
                // midnight and starts looking up a brand-new, not-yet-scored calendar day. Two DISTINCT
                // rows come out, so the two surfaces keep their own honest contracts:
                val logicalKey = com.noop.ui.logicalDayKeyNow()
                val localKey = java.time.LocalDate.now().toString()
                //  - todayRow: the naive/unscored today row. The ongoing notification's Recovery line must
                //    stay on THIS (honest-null until tonight is scored), never on a carried prior-day
                //    figure, or the lock-screen would silently show yesterday's Recovery% as if it were
                //    live, with no provenance caption.
                //  - anchorRow: today's row when scored, else the freshest STRICTLY-PRIOR scored day carried
                //    over (via the SHARED `widgetAnchorRow`, mirroring TodayScreen + the #547 future-day
                //    guard). ONLY the widget uses this, so the 2x2 widget shows the same day as Today rather
                //    than blanking in the small hours before tonight is scored. This keeps the service
                //    symmetric with AppViewModel, where only the widget push reads the anchor.
                NotifyTick(
                    state = state,
                    dayState = notifyDayStateCache.resolve(
                        days = days,
                        logicalKey = logicalKey,
                        localKey = localKey,
                        // The preference remains part of the per-tick cache key, so toggling the opt-out
                        // still takes effect on the next live-state emission without re-running the
                        // evaluation while the value is unchanged.
                        illnessEnabled = NoopPrefs.illnessWatch(this@WhoopConnectionService),
                    ),
                )
            }.catch { /* belt-and-braces: a frozen notification beats a dead process */ }
                // conflate + collect, NOT collectLatest (#82): the widget push suspends in Glance
                // machinery longer than the live-HR emission interval, so collectLatest cancelled
                // every push mid-flight and the widget starved on stale data the moment HR started
                // streaming. Conflation still processes only the latest value — just without the axe.
                .conflate()
                .collect { (state, dayState) ->
                // Honest-null: the notification's Recovery line reads the NAIVE today row, never the
                // carried anchor, so it stays blank until tonight's recovery actually lands (#911).
                postNotification(state, dayState.todayRecovery)
                // Banner transition (clear → raised) → real system notification; the notifier's
                // persisted day gate dedupes against the app-open (AppViewModel) call site.
                if (lastIllnessAlert == null && dayState.illness != null) {
                    IllnessAlertNotifier.onEvaluated(this@WhoopConnectionService, dayState.illness)
                }
                lastIllnessAlert = dayState.illness
                // Evaluated only when (SoC, charging) actually MOVES — see [lastBatteryAlertKey]. Both policies
                // are once-per-crossing and persisted, so re-running them on an unchanged pair can only repeat
                // work that already decided nothing.
                val batteryKey = state.batteryPct?.roundToInt() to state.charging
                if (batteryKey != lastBatteryAlertKey) {
                    // Battery alerts — low (≤15%) and charge-complete (100%). The once-per-crossing
                    // dedupe is persisted in NoopPrefs (BatteryAlertPolicy), so no in-memory pct tracking.
                    BatteryAlertNotifier.onBatteryUpdate(
                        this@WhoopConnectionService,
                        currPct = state.batteryPct?.roundToInt(),
                        charging = state.charging,
                    )
                    // ESCALATION 1 — critical SoC (iOS/macOS twin: BatteryNotifier.onCriticalBattery). A
                    // SECOND, lower crossing (12%) with its own persisted gate, because the 15% alert above
                    // latches until the cell recovers to 25%: measured, a user got that one warning and then
                    // total silence across the final ~3 h down to the ~10% hardware cutoff, and lost the
                    // night. Sits beside onBatteryUpdate rather than in the estimator block below because it
                    // is the same kind of pure SoC policy — no Room read, no slope fit.
                    BatteryAlertNotifier.onCriticalBattery(
                        this@WhoopConnectionService,
                        currPct = state.batteryPct?.roundToInt(),
                        charging = state.charging,
                    )
                }

                // Predictive runtime alert (iOS/macOS twin: BatteryNotifier.onRuntimeEstimate):
                // re-fit the "~X left" estimate from the persisted SoC series and warn at ≤24 h of
                // runtime, whatever the strap generation. Evaluated only when the battery % actually
                // changes (~8-min strap cadence), so the Room read + slope fit never rides every
                // live-state emission. Same samples/rated inputs as the Today badge, so the alert can
                // never disagree with the number on screen.
                val runtimePct = state.batteryPct?.roundToInt()
                if (runtimePct != null && runtimePct != lastRuntimeEvalPct) {
                    lastRuntimeEvalPct = runtimePct
                    runCatching {
                        val nowS = System.currentTimeMillis() / 1000
                        // #1304/#512: read the active strap's own SoC (banked under "whoop-<uuid>" for a
                        // 2nd strap), not the hardcoded canonical id. Same accessor as :606.
                        val samples = repo.batterySamples((application as NoopApplication).activeDeviceId, nowS - 14L * 86_400, nowS, limit = 2_000)
                            .mapNotNull { s -> s.soc?.let { s.ts to it } }
                        val rated = if (state.whoop5Detected) BatteryEstimator.ratedLifeHoursWhoop5
                                    else BatteryEstimator.ratedLifeHoursWhoop4
                        val estimate = BatteryEstimator.estimate(samples, rated)
                        BatteryAlertNotifier.onRuntimeEstimate(
                            this@WhoopConnectionService,
                            remainingHours = estimate?.hoursRemaining,
                            charging = state.charging,
                        )
                        // ESCALATION 2 — bedtime night-guard (iOS/macOS twin:
                        // BatteryNotifier.onBedtimeRunway). Near the LEARNED habitual bedtime, does the
                        // strap actually clear TONIGHT? Uses the cutoff-aware runtime, because the raw
                        // estimate is time-to-0% and the strap dies ~10 pp above that — ~6 h of phantom
                        // runway at the reference user's drain. Cold start (no learned midsleep, or
                        // fewer than 7 nights of durations) returns silent rather than inventing a
                        // bedtime, which would fire at the wrong hour for the shift/late sleepers the
                        // midsleep learner exists to serve. Rides the same SoC-change gate as the
                        // runtime alert, so it never adds work to the live-HR path.
                        refreshHabitualMidsleep()
                        BatteryAlertNotifier.onBedtimeRunway(
                            this@WhoopConnectionService,
                            nowSecOfDay = localSecOfDayNow(),
                            habitualMidsleepSec = habitualMidsleepCache,
                            typicalSleepHours = BatteryEstimator.typicalSleepHours(
                                dayState.days.mapNotNull { d -> d.totalSleepMin?.let { it / 60.0 } },
                            ),
                            usableRemainingHours = estimate?.let { BatteryEstimator.usableRemainingHours(it) },
                            charging = state.charging,
                        )
                    }
                }
                // Feed the home-screen widget from the same stream — this service is its heartbeat
                // while the app UI is closed. Throttled + no-op without a placed widget (the store
                // checks both); runCatching so a Glance hiccup never tears down the connection.
                runCatching {
                    WidgetSnapshotStore.push(
                        this@WhoopConnectionService,
                        WidgetSnapshot(
                            recoveryPct = dayState.widgetRecovery,
                            // Rest = the sleep_performance composite from the anchor row's banked stage
                            // figures (pure, honest-null until last night is scored); Effort = the 0-100
                            // strain. Widget-only carry, so it shows the same day as Today. (#516/#911)
                            restPct = dayState.widgetRest,
                            effortPct = dayState.widgetEffort,
                            heartRate = state.heartRate,
                            batteryPct = state.batteryPct?.roundToInt(),
                            connected = state.connected,
                            updatedAtMs = System.currentTimeMillis(),
                        ),
                    )
                }
            }
        }

        // Drive GPS route tracking from here so it OUTLIVES the UI (#215). While a GPS workout is
        // active we collect the platform location stream into the process-level [GpsSession]; the
        // ViewModel only observes that shared route. Gated on the active flag so the location radio is
        // off (and the FGS's location type unused) outside a GPS workout. Re-`start`s land here, so we
        // cancel + relaunch the gate, never stack collectors.
        gpsGateJob?.cancel()
        gpsGateJob = scope.launch {
            GpsSession.state
                .map { it.active }
                .distinctUntilChanged()
                .collect { active ->
                    gpsJob?.cancel()
                    gpsJob = null
                    if (active) {
                        // Re-post with the location service type added so background location is
                        // permitted while tracking; on Android 14+ a service that reads location in the
                        // background must declare the location FGS type. Reverted to connectedDevice-only
                        // when the workout ends (active=false re-posts the base type).
                        startForegroundCompat(buildNotification(ble.state.value, null), tracking = true)
                        // Workouts & GPS test mode (Test Centre): wire the GpsSession fix-progress sink to the
                        // .workouts-tagged strap log ONLY when the WORKOUTS mode is on (one SharedPreferences
                        // bool read here). When off, the sink stays null and the route fold is byte-identical.
                        GpsSession.workoutsLog =
                            if (com.noop.testcentre.TestCentre.from(applicationContext)
                                    .active(com.noop.testcentre.TestDomain.WORKOUTS)
                            ) {
                                { line -> ble.externalLog(line, com.noop.testcentre.TestDomain.WORKOUTS) }
                            } else {
                                null
                            }
                        gpsJob = launch {
                            // LocationTracker fails SAFE (no permission / no provider just ends the
                            // stream); runCatching guards an OEM throw so it can't tear down the FGS.
                            runCatching {
                                locationTracker.stream().collect { pt -> GpsSession.append(pt) }
                            }
                        }
                    } else {
                        GpsSession.workoutsLog = null   // route finished: drop the test-mode sink
                        startForegroundCompat(buildNotification(ble.state.value, null), tracking = false)
                    }
                }
        }

        // Smart alarm light-sleep watcher (#207). While the alarm is enabled and we're inside the wake
        // window, feed each live HR reading to the pure detector; on a lighter-phase reading, advance
        // the GUARANTEED alarm earlier (the scheduler clamps to the window and can never move it later
        // or cancel it — the hard deadline set via AlarmManager is independent of this collector). The
        // FGS is the only long-lived BLE collector, so this is what lets the smart move happen with the
        // app closed. If the service isn't running (user opted out of background) the hard deadline
        // still fires — that's the point of the fallback.
        alarmJob?.cancel()
        alarmJob = scope.launch {
            val store = SmartAlarmStore.from(this@WhoopConnectionService)
            ble.state
                .map { it.heartRate ?: 0 }
                .conflate()
                .collect { hr ->
                    if (!store.enabled || store.scheduledDeadlineMs <= 0L) {
                        inAlarmWindow = false
                        return@collect
                    }
                    val now = System.currentTimeMillis()
                    val inWindow = now in store.scheduledWindowStartMs until store.scheduledDeadlineMs
                    if (inWindow && !inAlarmWindow) sleepWatcher.reset()   // fresh night
                    inAlarmWindow = inWindow
                    if (!inWindow) return@collect
                    if (sleepWatcher.shouldWake(hr)) {
                        SmartAlarmScheduler.advanceTo(this@WhoopConnectionService, store, now)
                    }
                }
        }

        // START_NOT_STICKY: the FGS's job is to keep this process *alive* (which it does while
        // running, making OS kills unlikely). We deliberately do NOT resurrect after a kill, because
        // a fresh process has no strap/model context to reconnect with — the user reopening the app
        // re-establishes it. Resurrecting would only show a "Reconnecting…" notification that never
        // resolves.
        return START_NOT_STICKY
    }

    /** Promote to the foreground. Returns false (rather than throwing) if the platform refuses. When
     *  [tracking] a GPS workout we add the location FGS type — Android 14+ requires it for a service
     *  that reads location in the background (the manifest declares `connectedDevice|location`). */
    private fun startForegroundCompat(notification: Notification, tracking: Boolean = false): Boolean = runCatching {
        val type =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val locationType = if (tracking) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or locationType
            } else {
                0
            }
        ServiceCompat.startForeground(this, NOTIF_ID, notification, type)
    }.isSuccess

    /** Signature of the fields the notification actually renders (#216). The live HR stream emits ~1 Hz
     *  but the notification no longer shows BPM, so we only re-post when one of THESE changes — turning
     *  a per-beat wakeup into a handful of updates a day. */
    private var lastNotificationKey: String? = null

    private fun postNotification(state: LiveState, recoveryPct: Double? = null) {
        val key = listOf(
            state.connected,
            state.backfilling,
            recoveryPct?.roundToInt(),
            state.batteryPct?.roundToInt(),
            // The rendered TEXT depends on the locale, and a Service is never re-posted when the user
            // switches language — nothing above changes, so the notification would keep the previous
            // language until the connection or battery state happened to move. On a stable link with a
            // charged strap that is hours. (#867)
            resources.configuration.locales[0].toLanguageTag(),
        ).joinToString("|")
        if (key == lastNotificationKey) return
        lastNotificationKey = key
        // Defensive: a notify() throw (OEM quirk, revoked POST_NOTIFICATIONS on some ROMs) must not
        // crash the collector and tear down the connection we exist to keep alive.
        runCatching {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            mgr.notify(NOTIF_ID, buildNotification(state, recoveryPct))
        }
    }

    private fun buildNotification(state: LiveState, recoveryPct: Double?): Notification {
        // #216: deliberately NO live BPM in the title. A per-beat-changing notification forces the
        // foreground service to re-post (and wake the device) ~once a second all day, which is a real
        // battery cost for a number nobody reads off the lock screen. The title now reflects only the
        // connection / sync state, which changes rarely — see postNotification's dedup.
        val title = when {
            !state.connected   -> getString(R.string.fgs_title_reconnecting)
            state.backfilling  -> getString(R.string.fgs_title_syncing)
            else               -> getString(R.string.fgs_title_connected)
        }
        val detail = buildList {
            add(
                if (state.connected) getString(R.string.fgs_detail_streaming)
                else getString(R.string.fgs_detail_keeping_link),
            )
            recoveryPct?.let { add(getString(R.string.fgs_detail_recovery, it.roundToInt())) }
            state.batteryPct?.let { add(getString(R.string.fgs_detail_battery, it.roundToInt())) }
        }.joinToString("  ·  ")

        val openApp = PendingIntent.getActivity(
            this,
            0,
            appLaunchIntent(this),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stopAction = PendingIntent.getService(
            this,
            1,
            Intent(this, WhoopConnectionService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(title)
            .setContentText(detail)
            .setContentIntent(openApp)
            .addAction(0, getString(R.string.fgs_action_disconnect), stopAction)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    /**
     * Refresh [habitualMidsleepCache], at most hourly. `WhoopRepository.habitualMidsleepSec` reads the
     * WHOLE sleep history (both source namespaces, de-duplicated) and the learned value moves on a
     * timescale of WEEKS, so recomputing it on every ~8-minute battery reading would be a large read
     * for a number that cannot have changed. The timestamp advances BEFORE the read, so a failing read
     * cannot spin the throttle. Mirrors the iOS/macOS `AppModel.refreshHabitualMidsleep` cache.
     */
    private suspend fun refreshHabitualMidsleep() {
        val now = System.currentTimeMillis()
        if (habitualMidsleepCachedAtMs != 0L && now - habitualMidsleepCachedAtMs < 3_600_000L) return
        habitualMidsleepCachedAtMs = now
        // Thread the ACTIVE strap id so the learner unions active + canonical nights (#814/#1008),
        // exactly as SleepScreen does; the repository resolves the canonical sibling internally.
        habitualMidsleepCache = runCatching {
            repo.habitualMidsleepSec((application as NoopApplication).activeDeviceId)?.toInt()
        }.getOrNull()
    }

    /**
     * Local time-of-day in seconds, [0, 86400) — the clock the night-guard's bedtime window is in.
     * Reads the CURRENT zone, so a traveller's window follows them rather than sticking to home time.
     * Twin of the Swift `AppModel.localSecOfDayNow`.
     */
    private fun localSecOfDayNow(now: java.time.LocalTime = java.time.LocalTime.now()): Int =
        now.toSecondOfDay()

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        // Defensive: channel creation can throw on some OEM ROMs / under memory pressure; never let
        // that crash onStartCommand (it would take the FGS — and the connection — down with it).
        runCatching {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            // Deliberately NOT skipping when the channel already exists. createNotificationChannel is
            // idempotent and updates the name/description of an existing channel, which is the only way
            // those follow a language change — they are set once at creation and are user-visible in
            // system Settings, so an early return here left them in the install-time language forever.
            // Everything else about the channel is unchanged, and importance/sound are not re-applied
            // by the OS once a user has adjusted them.
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.fgs_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.fgs_channel_desc)
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            mgr.createNotificationChannel(channel)
        }
    }

    override fun onDestroy() {
        if (bluetoothReceiverRegistered) {
            // unregisterReceiver throws if it was never registered; the flag guards that, and runCatching
            // covers the rare case the OS already reclaimed it.
            runCatching { unregisterReceiver(bluetoothStateReceiver) }
            runCatching { unregisterReceiver(bondStateReceiver) }
            bluetoothReceiverRegistered = false
        }
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "noop_strap_connection"
        private const val NOTIF_ID = 4201
        const val ACTION_STOP = "com.noop.ble.action.STOP_CONNECTION"

        /**
         * Promote the process to the foreground so the strap stays connected. Safe to call when
         * already running. MUST be called from a foreground context (we call it from connect / the
         * Settings toggle) to satisfy Android 12+'s background-start rule. Defensive: any failure is
         * swallowed so it can never break the core connect flow.
         */
        fun start(context: Context) {
            runCatching {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, WhoopConnectionService::class.java),
                )
            }
        }

        /** Drop the foreground promotion. The connection itself is torn down by the caller. */
        fun stop(context: Context) {
            runCatching { context.stopService(Intent(context, WhoopConnectionService::class.java)) }
        }
    }
}
