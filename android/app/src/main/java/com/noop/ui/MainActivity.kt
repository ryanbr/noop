package com.noop.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.noop.BuildConfig
import com.noop.NoopApplication
import com.noop.ble.WhoopModel
import com.noop.data.DemoSeeder
import com.noop.data.WhoopRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Single-activity host. Requests the runtime BLE permissions the strap connection
 * needs, then renders the Compose tree under [NoopTheme]. The design system is
 * dark-only, so we draw edge-to-edge over the near-black [Palette.surfaceBase].
 */
class MainActivity : ComponentActivity() {

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLanguagePrefs.wrap(newBase))
    }

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            // Permission results flow back into the BLE client's own runtime checks;
            // the UI simply reflects connection state. No blocking here.
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        // Load the saved "Card transparency" so every frosted card renders at the chosen opacity from launch.
        CardAppearance.init(this)

        // Demo build only: preload a full synthetic dataset so every screen is populated
        // out of the box (no strap, no import). No-op once seeded; never runs on the full app.
        if (BuildConfig.ENABLE_DEMO) {
            lifecycleScope.launch(Dispatchers.IO) {
                runCatching { DemoSeeder.seedIfEmpty(WhoopRepository.from(applicationContext)) }
                // Also seed a 2nd PAIRED device (Polar H10) so the Devices screen shows WHOOP (Active)
                // + a paired strap out of the box. No-op once seeded / if a real pairing exists.
                runCatching {
                    DemoSeeder.seedDemoDeviceIfNeeded((application as NoopApplication).deviceRegistry)
                }
            }
        }

        // Only pre-warm permissions at launch for already-onboarded users. First-run onboarding
        // requests each permission at the step that explains it, Bluetooth when the Connect step
        // appears, notifications when it enables the background keep-alive, so the OS prompt never
        // lands before the screen that justifies it.
        if (NoopPrefs.of(this).getBoolean(NoopPrefs.KEY_ONBOARDED, false)) {
            requestBlePermissions()
        }

        // Re-arm the daily debug export (#510) so its schedule self-heals after a reboot or app update
        // (WorkManager is KEEP, so this is a no-op when already scheduled, and cancels itself when the
        // feature is off). Wrapped because a WorkManager hiccup must never block launch.
        runCatching { DebugExportScheduler.reschedule(applicationContext) }

        // Backup & Sync (#791): self-heal the daily auto-backup schedule (no-op when off / no folder),
        // and run a DEFERRED on-launch catch-up backup. Must-fix #4: the catch-up is gated on the toggle
        // being ON, runs fully off the main thread on Dispatchers.IO, and is launched AFTER the
        // launch-critical setup so a 100MB+ whole-DB zip can never block app startup. Cheap (two prefs
        // reads) when the feature is off, which is the default.
        runCatching { BackupSync.reschedule(applicationContext) }
        lifecycleScope.launch(Dispatchers.IO) {
            runCatching { BackupSync.catchUpIfDue(applicationContext) }
        }

        // Load the Light/Dark/System + chart-colour preferences before first composition so the theme
        // and chart ramps are correct from the very first frame (no flash).
        AppearancePrefs.load(this)
        ChartStylePrefs.load(this)
        AccentPrefs.load(this)   // chrome accent colour (mint / WHOOP blue / custom), live snapshot state
        // Decode the optional on-device profile photo (if set) before first composition so the Today
        // header + Settings avatars show it from the first frame. No-op when no photo is set.
        ProfileAvatarStore.load(this)

        setContent {
            NoopTheme {
                NoopRoot()
            }
        }
    }

    /** Request the BLE permissions appropriate to the running OS version. */
    private fun requestBlePermissions() {
        val needed = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android 12+: granular Bluetooth permissions.
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                // Pre-12: location is required for BLE scanning.
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }.toTypedArray()

        if (needed.isNotEmpty()) permissionLauncher.launch(needed)
    }
}

internal fun appLaunchIntent(context: Context): Intent =
    context.packageManager.getLaunchIntentForPackage(context.packageName)
        ?.apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
        }
        ?: Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
        }

// MARK: - First-run / changelog gating (mirrors macOS ContentView.swift)
//
// Two persisted flags decide what the user sees on launch, exactly like the macOS
// ZStack-over-RootView:
//   • "noop.onboarded"               (Boolean, default false)
//   • "noop.lastSeenChangelogVersion" (String,  default "")
//
// Gate:
//   !onboarded                              → OnboardingScreen. On finish, mark onboarded
//                                             AND set lastSeen = CURRENT_VERSION, so a brand-new
//                                             user who just read the expectations doesn't ALSO
//                                             get the changelog popped at them.
//   onboarded && lastSeen != CURRENT_VERSION → existing user who updated: show WhatsNewSheet once,
//                                             over the live AppRoot, until they dismiss it.
//
// SharedPreferences isn't reactive, so each value is read once into a remembered
// mutableState and writes go through .edit().apply() + a state update to recompose.

/** Shared accessor for the onboarding / changelog flags (the macOS @AppStorage equivalent). */
object NoopPrefs {
    const val NAME = "noop_prefs"
    const val KEY_ONBOARDED = "noop.onboarded"
    const val KEY_LAST_SEEN_CHANGELOG = "noop.lastSeenChangelogVersion"
    /** Terms-of-use version the user last accepted. Empty until the first-run gate is accepted; a
     *  material terms change bumps [Terms.CURRENT_VERSION] and re-prompts. Mirrors macOS @AppStorage. */
    const val KEY_ACCEPTED_TERMS_VERSION = "noop.acceptedTermsVersion"
    /** ISO-8601 timestamp of the last terms acceptance — the on-device consent record (version + when). */
    const val KEY_ACCEPTED_TERMS_AT = "noop.acceptedTermsAt"

    /** "Keep connected in the background", drives [com.noop.ble.WhoopConnectionService]. Default on. */
    const val KEY_BACKGROUND_CONNECTION = "noop.backgroundConnection"

    /** "Continuous HRV capture", when on (AND background connection is on), NOOP holds the dense
     *  realtime HR stream armed even with no Live screen open, so the strap banks beat-to-beat R-R 24/7
     *  for far better overnight HRV/recovery/sleep. Uses more battery (continuous HR streaming). Default
     *  OFF. Drives [com.noop.ble.WhoopBleClient.setKeepStreamForData] via [AppViewModel]. */
    const val KEY_CONTINUOUS_HRV = "noop.continuousHrv"

    /** "Overnight only" refinement of Continuous HRV capture (#927): when on (with [KEY_CONTINUOUS_HRV]),
     *  the dense realtime stream is armed only inside the nightly quiet-hours window (22:00 to 07:00 by
     *  default, wrap-aware, local wall time) instead of 24/7, roughly halving the battery cost. Defaults
     *  ON for fresh installs and OFF for anyone who has already used Continuous HRV (#1008), so existing
     *  users keep the always-on behaviour with no migration. Read by
     *  [com.noop.ble.WhoopBleClient] at every arm site (re-derived at arm time, never cached). */
    const val KEY_CONTINUOUS_HRV_OVERNIGHT = "noop.continuousHrvOvernight"

    /** The calendar day (yyyy-MM-dd) on which the morning-journal nudge was last shown, keeps the
     *  Sleep screen's "Good morning" sheet to at most once per day. */
    const val KEY_LAST_JOURNAL_PROMPT = "noop.lastJournalPromptDay"

    /** "Journal reminder" (#627). When ON, Today shows a dismissible card whenever nothing has been
     *  logged to today's journal yet, and the Sleep screen's morning sheet may fire — one switch gates
     *  both surfaces. Default ON. Mirrors iOS @AppStorage("noopJournalReminder"). */
    const val KEY_JOURNAL_REMINDER_ENABLED = "noop.journalReminder"

    /** The calendar day (yyyy-MM-dd) on which the Today journal-reminder card was last dismissed, so an
     *  X hides it until the next day (per-day, like [KEY_LAST_JOURNAL_PROMPT]). */
    const val KEY_JOURNAL_REMINDER_DISMISSED_DAY = "noop.journalReminderDismissedDay"

    /** "Debug logging", when on, the strap log is also written to logcat (`adb`). Default OFF so a
     *  normal user never emits the connection log to the system log; the in-app ring buffer (and the
     *  "Share strap log" export) work regardless. See [com.noop.ble.WhoopBleClient.debugLogcat]. */
    const val KEY_DEBUG_LOGGING = "noop.debugLogging"

    /** "Broadcast heart rate", when on, NOOP acts as a standard BLE Heart Rate peripheral (0x180D /
     *  0x2A37) and re-broadcasts the live strap HR so a gym treadmill / Zwift / Peloton can read it.
     *  LOCAL Bluetooth only, nothing leaves the device. Default OFF. Drives [com.noop.ble.HrBroadcaster]
     *  via [AppViewModel]. Distinct from the WHOOP strap's own "broadcast HR" firmware config. */
    const val KEY_HR_BROADCAST = "noop.hrBroadcast"

    const val KEY_ANALYZE_WATERMARK = "noop.analyzeWatermark"

    /** "Power saving" (#477): when on, NOOP stretches its periodic strap-sync cadence (15 → 45 min) while
     *  the STRAP is discharging at/below [KEY_POWER_SAVING_BATTERY_PCT].
     *
     *  This doc used to say "the phone is discharging … OR the OS Battery Saver is on". Both were wrong:
     *  `WhoopBleClient.nextBackfillDelayMs` reads `batteryPctAndCharging()`, which is the connected
     *  STRAP's battery, and nothing on that path touches PowerManager. The intent is deliberate and
     *  documented at that function — the levers reduce what the STRAP transmits, so they extend the
     *  strap's life — but the description here promised a phone-battery behaviour that does not exist,
     *  which is exactly what a triager reaches for on a phone-drain report like #1005.
     *
     *  Benign — the strap banks to flash meanwhile, so sync just batches; no data loss, no link risk.
     *  Default OFF. Drives [com.noop.ble.WhoopBleClient.setLowBatteryOffloadThrottle] via [AppViewModel]. */
    const val KEY_POWER_SAVING = "noop.powerSaving"
    /** Battery-% threshold for [KEY_POWER_SAVING] (10/15/20/25/30). Default 20. */
    const val KEY_POWER_SAVING_BATTERY_PCT = "noop.powerSavingBatteryPct"
    /** "Pause HRV capture when the strap is low" (#477): when on, NOOP releases the held-open background
     *  continuous-HRV stream while the STRAP is discharging at/below [KEY_POWER_SAVING_BATTERY_PCT]
     *  (a Live screen still arms it on demand).
     *
     *  Named "in Battery Saver" here and described as keying on the OS Battery Saver, which it does not:
     *  `reconcileRealtime` gates on `idleThrottleActive(strap battery, …)`. Same correction as
     *  [KEY_POWER_SAVING] above.
     *
     *  The SHIPPED COPY was always right — `power_saving_hrv_pause_desc` says "while your strap's battery
     *  is low", `power_saving_kick_in` reads "Kick in at (strap battery)", and the label is just "Pause
     *  HRV capture" with no mention of Battery Saver. So no user was ever misled; the wrong description
     *  lived only here, where a maintainer triaging a battery report would read it. Which is what
     *  happened on #1005.
     *  A sub-option of [KEY_POWER_SAVING] — only effective while the master is on. Default ON (so enabling
     *  Power saving pauses capture by default; the user can turn it off). Drives
     *  [com.noop.ble.WhoopBleClient.setPauseCaptureOnPowerSave] via [AppViewModel]. */
    const val KEY_PAUSE_HRV_ON_POWER_SAVE = "noop.pauseHrvOnPowerSave"

    fun of(context: Context): SharedPreferences =
        context.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    /** "Power saving" master (battery-adaptive sync cadence). Default off. */
    fun powerSaving(context: Context): Boolean =
        of(context).getBoolean(KEY_POWER_SAVING, false)

    fun setPowerSaving(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_POWER_SAVING, enabled).apply()
    }

    /** Battery-% threshold for power saving (default 20). */
    fun powerSavingBatteryPct(context: Context): Int =
        of(context).getInt(KEY_POWER_SAVING_BATTERY_PCT, 20)

    fun setPowerSavingBatteryPct(context: Context, pct: Int) {
        of(context).edit().putInt(KEY_POWER_SAVING_BATTERY_PCT, pct).apply()
    }

    /** Pause continuous-HRV capture while Battery Saver is on (sub-option of Power saving). Default ON. */
    fun pauseHrvOnPowerSave(context: Context): Boolean =
        of(context).getBoolean(KEY_PAUSE_HRV_ON_POWER_SAVE, true)

    fun setPauseHrvOnPowerSave(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_PAUSE_HRV_ON_POWER_SAVE, enabled).apply()
    }

    /** EXPERIMENTAL (#533): escalate the GATT connection interval to HIGH for the bounded historical
     *  offload burst, so a large backlog drains faster. Drives the SAFE half of #477's connection-priority
     *  management via [com.noop.ble.WhoopBleClient.setConnectionPriorityManagement]; the risky idle
     *  throttle stays off, and the live/overnight stream never escalates.
     *
     *  DEFAULT OFF and behind an "(experimental)" label on purpose: BLE behaviour cannot be CI- or
     *  Linux-tested, so both the speedup and its battery cost need real-strap field reports before this
     *  could ever be considered for default-on. */
    const val KEY_FAST_HISTORY_SYNC = "noop.fastHistorySync"

    fun fastHistorySync(context: Context): Boolean =
        of(context).getBoolean(KEY_FAST_HISTORY_SYNC, false)

    fun setFastHistorySync(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_FAST_HISTORY_SYNC, enabled).apply()
    }

    /** EXPERIMENTAL (#477): strap-battery % at/below which an IDLE link drops to LOW_POWER while the
     *  strap is discharging. 0 = off, which is the default and today's behaviour for everyone.
     *
     *  Two preconditions, both easy to miss. It needs [KEY_FAST_HISTORY_SYNC] on as well, because
     *  `refreshConnectionPriority` early-returns without connection-priority management; and it keys on
     *  the STRAP's battery, not the phone's, so a healthy strap never trips it however low the phone is.
     *  Neither is a bug, but a value set here alone will look like it does nothing.
     *
     *  Deliberately has NO Settings control yet. #477's validation plan needs the throttle enabled on a
     *  real strap and nobody could do that while the caller passed a hard-coded 0; this makes it
     *  reachable, without shipping a user-facing row whose two preconditions are invisible. LOW_POWER
     *  lengthens the connection interval, which can drop a link, so it stays opt-in until a field report
     *  says otherwise.
     *
     *  CLAMPED to 0 or 10..30 on read: settable out-of-band on a debug build, and an unclamped 95 would
     *  engage the throttle at essentially all times, which is a foot-gun rather than a test. */
    const val KEY_IDLE_THROTTLE_BATTERY_PCT = "noop.idleThrottleBatteryPct"

    fun idleThrottleBatteryPct(context: Context): Int =
        clampIdleThrottlePct(of(context).getInt(KEY_IDLE_THROTTLE_BATTERY_PCT, 0))

    fun setIdleThrottleBatteryPct(context: Context, pct: Int) {
        of(context).edit().putInt(KEY_IDLE_THROTTLE_BATTERY_PCT, clampIdleThrottlePct(pct)).apply()
    }

    /** 0 (off) or 10..30, the range every other battery threshold in this file offers. Anything else is
     *  out of range rather than a smaller/larger preference, so it reads as OFF - failing closed, because
     *  the failure mode of the alternative is a link that keeps dropping. Pure, so it is testable
     *  without a Context. */
    internal fun clampIdleThrottlePct(raw: Int): Int = if (raw in 10..30) raw else 0

    /** EXPERIMENTAL (#533): prefer the LE 2M PHY around the historical offload. LE 2M doubles the symbol
     *  rate, so the same bytes spend half the air-time — it should cost LESS radio energy per byte, not
     *  more (unlike [KEY_FAST_HISTORY_SYNC]'s connection-interval lever). NOOP has never called
     *  setPreferredPhy, so every offload to date has run on 1M. Orthogonal to that lever; they stack, and
     *  they are separate toggles so a field report can attribute which one did what.
     *
     *  DEFAULT OFF: it is a preference the strap may decline, 2M trades range for speed, and BLE behaviour
     *  can't be CI-tested — the negotiated PHY and the speedup both need real-strap field reports. The
     *  request always allows 1M too, so the controller can fall back. */
    const val KEY_FAST_LINK_PHY = "noop.fastLinkPhy"

    fun fastLinkPhy(context: Context): Boolean =
        of(context).getBoolean(KEY_FAST_LINK_PHY, false)

    fun setFastLinkPhy(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_FAST_LINK_PHY, enabled).apply()
    }

    /** #836, the raw-HR fingerprint ("count:maxTs") the last COMPLETED idle rescore scored against. The
     *  15-min backstop tick skips when the current fingerprint equals this; cleared implicitly by any HR
     *  insert/delete (the fingerprint moves). Mirrors the Swift `analyzeWatermark` UserDefaults key. */
    fun analyzeWatermark(context: Context): String? =
        of(context).getString(KEY_ANALYZE_WATERMARK, null)

    fun setAnalyzeWatermark(context: Context, fingerprint: String) {
        of(context).edit().putString(KEY_ANALYZE_WATERMARK, fingerprint).apply()
    }

    /** Whether NOOP should hold the strap connection open via a foreground service. Default true. */
    fun backgroundConnection(context: Context): Boolean =
        of(context).getBoolean(KEY_BACKGROUND_CONNECTION, true)

    fun setBackgroundConnection(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_BACKGROUND_CONNECTION, enabled).apply()
    }

    /** Whether NOOP keeps the dense realtime HR stream armed 24/7 for continuous HRV capture. Default
     *  false. Only takes effect while [backgroundConnection] is also on. */
    fun continuousHrv(context: Context): Boolean =
        of(context).getBoolean(KEY_CONTINUOUS_HRV, false)

    fun setContinuousHrv(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_CONTINUOUS_HRV, enabled).apply()
    }

    /**
     * Whether Continuous HRV capture arms the stream only inside the nightly window (#927).
     *
     * Defaults to ON for anyone who has never touched Continuous HRV, and to OFF for anyone who has
     * (#1008). WHOOP publishes no daytime HRV figure at all — its reading is an overnight one — so a
     * 24/7 stream has no official-app analogue, and the setting's own copy says overnight-only roughly
     * halves the battery cost. Making the cheaper, WHOOP-comparable behaviour the one you get by
     * default is the point; the expensive one stays a deliberate choice.
     *
     * The unset case is resolved from whether [KEY_CONTINUOUS_HRV] exists rather than by writing a
     * migration, because the ONLY thing that must not happen is silently narrowing capture for someone
     * already relying on it. Presence of that key means the user has been through this screen and
     * experienced always-on; absence means a fresh install, which gets the new default. A user who
     * toggled the base setting on and back off keeps always-on too — conservative on purpose, since
     * they have seen the old behaviour.
     */
    fun continuousHrvOvernight(context: Context): Boolean =
        of(context).getBoolean(KEY_CONTINUOUS_HRV_OVERNIGHT, true)

    /**
     * One-time migration for the #1008 default flip. Called once at process start, BEFORE anything reads
     * the setting.
     *
     * The default moved from OFF to ON, so an install that predates the change has to be pinned to OFF
     * explicitly or it would be silently narrowed to overnight-only capture — removing daytime data the
     * user opted in for. "Predates the change" is read as "has ever toggled Continuous HRV", i.e. the
     * base key exists.
     *
     * Deciding this at READ time instead does not work, and the way it fails is worth recording: the
     * discriminator would be the base key, which the user's own opt-in creates — so a fresh install
     * would default to ON, then flip to OFF the moment they enabled Continuous HRV, which is the exact
     * opposite of the intent. The decision has to be pinned before the user can touch either setting.
     *
     * Idempotent: writes only when the overnight key is absent and the base key is present, so it is a
     * no-op on every launch after the first and on every fresh install.
     */
    fun migrateContinuousHrvOvernightDefault(context: Context) {
        val prefs = of(context)
        if (shouldPinLegacyOvernightDefault(
                hasOvernightChoice = prefs.contains(KEY_CONTINUOUS_HRV_OVERNIGHT),
                hasUsedContinuousHrv = prefs.contains(KEY_CONTINUOUS_HRV),
            )
        ) {
            prefs.edit().putBoolean(KEY_CONTINUOUS_HRV_OVERNIGHT, false).apply()
        }
    }

    /**
     * The migration's decision, lifted out so it is testable without a `Context`. Twin of the Swift
     * `PuffinExperiment.shouldPinLegacyOvernightDefault`.
     *
     * Pin the OLD default only for an install that has used Continuous HRV and never chose an overnight
     * setting. Everything else is left alone: an explicit choice is already recorded, or the install is
     * fresh and should take the new default.
     *
     * Note what this is NOT keyed on: the READ. An earlier attempt resolved the default at read time
     * from [hasUsedContinuousHrv], which the user's own opt-in creates — so a fresh install read ON and
     * then flipped to OFF the moment Continuous HRV was enabled. Running the decision once at launch is
     * what makes the answer stable, because it is taken before the user can change the inputs.
     */
    internal fun shouldPinLegacyOvernightDefault(
        hasOvernightChoice: Boolean,
        hasUsedContinuousHrv: Boolean,
    ): Boolean = !hasOvernightChoice && hasUsedContinuousHrv

    fun setContinuousHrvOvernight(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_CONTINUOUS_HRV_OVERNIGHT, enabled).apply()
    }

    /** Whether the strap log is mirrored to logcat. Default false (normal users don't log to adb). */
    fun debugLogging(context: Context): Boolean =
        of(context).getBoolean(KEY_DEBUG_LOGGING, false)

    fun setDebugLogging(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_DEBUG_LOGGING, enabled).apply()
    }

    /** #1121: whether the opt-in "detailed capture" rolling strap-log file is on. Persisted so capture
     *  RESUMES after the process is killed (AppViewModel re-arms the BLE client from this on launch). */
    const val KEY_DETAILED_CAPTURE = "noop.detailedCapture"
    fun detailedCapture(context: Context): Boolean =
        of(context).getBoolean(KEY_DETAILED_CAPTURE, false)

    fun setDetailedCapture(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_DETAILED_CAPTURE, enabled).apply()
    }

    /** Whether NOOP re-broadcasts its live HR as a standard BLE Heart Rate peripheral. Default OFF. */
    fun hrBroadcast(context: Context): Boolean =
        of(context).getBoolean(KEY_HR_BROADCAST, false)

    fun setHrBroadcast(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_HR_BROADCAST, enabled).apply()
    }

    /** "Buzz WHOOP 4" (#536): arm the strap's firmware alarm at the phone smart alarm's earliest wake
     *  time, so the strap buzzes first and the OS alarm fires at the hard deadline as backup. Default OFF. */
    const val KEY_BUZZ_WHOOP4_WITH_ALARM = "noop.buzzWhoop4WithAlarm"
    fun buzzWhoop4WithAlarm(context: Context): Boolean =
        of(context).getBoolean(KEY_BUZZ_WHOOP4_WITH_ALARM, false)

    fun setBuzzWhoop4WithAlarm(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_BUZZ_WHOOP4_WITH_ALARM, enabled).apply()
    }

    /** Launcher-icon preference (v3 "Titanium & Gold"). false = machined-titanium (.IconDefault,
     *  the default); true = blued/dark-blue titanium (.IconNavy). The actual swap is done by
     *  enabling exactly one of the two <activity-alias> entries via PackageManager, this bool just
     *  records the user's choice so the App Icon control reflects it across restarts. */
    const val KEY_APP_ICON_NAVY = "noop.appIconNavy"

    fun appIconNavy(context: Context): Boolean =
        of(context).getBoolean(KEY_APP_ICON_NAVY, false)

    fun setAppIconNavy(context: Context, navy: Boolean) {
        of(context).edit().putBoolean(KEY_APP_ICON_NAVY, navy).apply()
    }

    /** Imperial/Metric display preference (D#103). Display-only, stored data stays SI. The length/mass
     *  system is read by [UnitPrefs.system]; the temperature override (empty = "match the system") by
     *  [UnitPrefs.temperature]. Mirrors macOS @AppStorage("units.system" / "units.temperature"). */
    const val KEY_UNIT_SYSTEM = "units.system"
    const val KEY_TEMPERATURE_UNIT = "units.temperature"

    fun setUnitSystem(context: Context, system: UnitSystem) {
        of(context).edit().putString(KEY_UNIT_SYSTEM, system.raw).apply()
    }

    /** Persist the temperature override, or pass null to clear it back to "match the system". */
    fun setTemperatureUnit(context: Context, unit: TemperatureUnit?) {
        of(context).edit().apply {
            if (unit == null) remove(KEY_TEMPERATURE_UNIT) else putString(KEY_TEMPERATURE_UNIT, unit.raw)
        }.apply()
    }

    /** Health Connect periodic auto-sync (Samsung Health → Health Connect → NOOP). Default OFF.
     *  Interval in hours (default 12). Last successful sync as epoch millis (0 = never). */
    const val KEY_HC_AUTO_SYNC = "noop.hcAutoSync"
    const val KEY_HC_SYNC_HOURS = "noop.hcSyncHours"
    const val KEY_HC_LAST_SYNC = "noop.hcLastSync"

    fun hcAutoSync(context: Context): Boolean =
        of(context).getBoolean(KEY_HC_AUTO_SYNC, false)

    fun setHcAutoSync(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_HC_AUTO_SYNC, enabled).apply()
    }

    fun hcSyncHours(context: Context): Int =
        of(context).getInt(KEY_HC_SYNC_HOURS, 12)

    fun setHcSyncHours(context: Context, hours: Int) {
        of(context).edit().putInt(KEY_HC_SYNC_HOURS, hours).apply()
    }

    fun hcLastSync(context: Context): Long =
        of(context).getLong(KEY_HC_LAST_SYNC, 0L)

    fun setHcLastSync(context: Context, epochMs: Long) {
        of(context).edit().putLong(KEY_HC_LAST_SYNC, epochMs).apply()
    }

    /** Health Connect writeback (NOOP's computed metrics → HC, for other apps). Default OFF. */
    const val KEY_HC_WRITEBACK = "noop.hcWriteback"

    fun hcWriteback(context: Context): Boolean =
        of(context).getBoolean(KEY_HC_WRITEBACK, false)

    fun setHcWriteback(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_HC_WRITEBACK, enabled).apply()
    }

    /** Last writeback OUTCOME (#660) — surfaced in Data Sources so a silently-failing share (revoked
     *  permission, provider error) is visible instead of a healthy-looking toggle. [KEY_HC_WB_STATUS]
     *  holds a PII-safe category ([HC_WB_OK] / [HC_WB_PERMISSION_DENIED] / [HC_WB_REMOTE_ERROR]); "" = never. */
    const val KEY_HC_WB_STATUS = "noop.hcWritebackStatus"
    const val KEY_HC_WB_AT = "noop.hcWritebackAtMs"
    const val KEY_HC_WB_WRITTEN = "noop.hcWritebackWritten"
    const val HC_WB_OK = "OK"
    const val HC_WB_PERMISSION_DENIED = "PERMISSION_DENIED"
    const val HC_WB_REMOTE_ERROR = "REMOTE_ERROR"

    fun hcWritebackStatus(context: Context): String = of(context).getString(KEY_HC_WB_STATUS, "") ?: ""
    fun hcWritebackAt(context: Context): Long = of(context).getLong(KEY_HC_WB_AT, 0L)
    fun hcWritebackWritten(context: Context): Int = of(context).getInt(KEY_HC_WB_WRITTEN, 0)
    fun setHcWritebackStatus(context: Context, code: String, written: Int, atMs: Long) {
        of(context).edit()
            .putString(KEY_HC_WB_STATUS, code)
            .putInt(KEY_HC_WB_WRITTEN, written)
            .putLong(KEY_HC_WB_AT, atMs)
            .apply()
    }

    /** #528, last HR sample epoch-second exported to Health Connect (0 = nothing exported yet). The
     *  HR share-back only emits samples newer than this, so each writeback is incremental. */
    const val KEY_HC_HR_FRONTIER = "noop.hcHrFrontierTs"

    fun hcHrFrontier(context: Context): Long =
        of(context).getLong(KEY_HC_HR_FRONTIER, 0L)

    fun setHcHrFrontier(context: Context, tsSec: Long) {
        of(context).edit().putLong(KEY_HC_HR_FRONTIER, tsSec).apply()
    }

    /** Smart alarm: arm the strap's firmware alarm to buzz at a wake time. Default off; default time 07:00. */
    const val KEY_SMART_ALARM = "noop.smartAlarmEnabled"
    const val KEY_SMART_ALARM_MINUTES = "noop.smartAlarmMinutes"

    fun smartAlarmEnabled(context: Context): Boolean =
        of(context).getBoolean(KEY_SMART_ALARM, false)

    fun setSmartAlarmEnabled(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_SMART_ALARM, enabled).apply()
    }

    /** Wake time as minutes since midnight (default 420 = 07:00). */
    fun smartAlarmMinutes(context: Context): Int =
        of(context).getInt(KEY_SMART_ALARM_MINUTES, 7 * 60)

    fun setSmartAlarmMinutes(context: Context, minutes: Int) {
        of(context).edit().putInt(KEY_SMART_ALARM_MINUTES, minutes).apply()
    }

    /** Weekdays the smart alarm fires on (Calendar.DAY_OF_WEEK: 1=Sun … 7=Sat). Empty = every day,      *  the backward-compatible default for anyone upgrading from before per-day scheduling (#539). Stored
     *  as a string set; only valid day numbers (1…7) are kept so a corrupted entry can't schedule a
     *  bogus day. Mirrors macOS `BehaviorStore.smartAlarmWeekdays`. */
    const val KEY_SMART_ALARM_WEEKDAYS = "noop.smartAlarmWeekdays"

    fun smartAlarmWeekdays(context: Context): Set<Int> =
        of(context).getStringSet(KEY_SMART_ALARM_WEEKDAYS, emptySet())
            ?.mapNotNull { it.toIntOrNull() }?.filter { it in 1..7 }?.toSet() ?: emptySet()

    fun setSmartAlarmWeekdays(context: Context, days: Set<Int>) {
        val clean = days.filter { it in 1..7 }.map { it.toString() }.toSet()
        of(context).edit().putStringSet(KEY_SMART_ALARM_WEEKDAYS, clean).apply()
    }

    /** Per-weekday wake-time OVERRIDES (reimpl of @MumiZed's PR #554): a map of Calendar.DAY_OF_WEEK
     *  (1=Sun…7=Sat) → minute-of-day. A day with no entry uses the default [smartAlarmMinutes]. Stored as
     *  a "dow:minute" string set; only valid days (1…7) and minutes [0,1440) survive a load, so a corrupt
     *  entry can never schedule a bogus time. Empty = no overrides (the pre-#554 behaviour). */
    const val KEY_SMART_ALARM_OVERRIDES = "noop.smartAlarmDayOverrides"

    fun smartAlarmDayOverrides(context: Context): Map<Int, Int> =
        of(context).getStringSet(KEY_SMART_ALARM_OVERRIDES, emptySet())
            ?.mapNotNull { entry ->
                val parts = entry.split(":")
                if (parts.size != 2) return@mapNotNull null
                val dow = parts[0].toIntOrNull() ?: return@mapNotNull null
                val min = parts[1].toIntOrNull() ?: return@mapNotNull null
                if (dow !in 1..7 || min !in 0 until 24 * 60) return@mapNotNull null
                dow to min
            }?.toMap() ?: emptyMap()

    fun setSmartAlarmDayOverrides(context: Context, overrides: Map<Int, Int>) {
        val clean = overrides
            .filterKeys { it in 1..7 }
            .filterValues { it in 0 until 24 * 60 }
            .map { (dow, min) -> "$dow:$min" }
            .toSet()
        of(context).edit().putStringSet(KEY_SMART_ALARM_OVERRIDES, clean).apply()
    }

    /** HR-zone haptic coaching: buzz the strap on entering the top zone (ease off) and, when the
     *  recovery buzz is on, on dropping back to Zone 1. Zone-based off the profile's HR-max; mirrors
     *  macOS. Coaching default off; recovery buzz default on (matches macOS's always-both behaviour).
     *  Reimplemented from @cbarrado's PR #350. */
    const val KEY_ZONE_COACHING = "noop.zoneCoaching"
    const val KEY_ZONE_COACH_RECOVERY = "noop.zoneCoachRecovery"

    fun zoneCoaching(context: Context): Boolean =
        of(context).getBoolean(KEY_ZONE_COACHING, false)

    fun setZoneCoaching(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_ZONE_COACHING, enabled).apply()
    }

    /** Whether to also buzz on recovering to Zone 1. Default ON (the macOS behaviour). */
    fun zoneCoachRecovery(context: Context): Boolean =
        of(context).getBoolean(KEY_ZONE_COACH_RECOVERY, true)

    fun setZoneCoachRecovery(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_ZONE_COACH_RECOVERY, enabled).apply()
    }

    /** Illness early-warning (banner + notification). Default ON, the watch has always run on
     *  Android, so this is an opt-OUT; macOS is opt-in (behavior.illnessWatch, default off). */
    const val KEY_ILLNESS_WATCH = "noop.illnessWatch"

    fun illnessWatch(context: Context): Boolean =
        of(context).getBoolean(KEY_ILLNESS_WATCH, true)

    fun setIllnessWatch(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_ILLNESS_WATCH, enabled).apply()
    }

    /** Cycle awareness (v5): read a coarse menstrual-cycle PHASE from the nightly skin-temperature
     *  shift. OPT-IN, default OFF (manual-first ethos), the Health hub's Cycle card only renders once
     *  this is on. Awareness only; never contraception / fertility / diagnosis. */
    const val KEY_CYCLE_TRACKING = "noop.cycleTracking"

    fun cycleTracking(context: Context): Boolean =
        of(context).getBoolean(KEY_CYCLE_TRACKING, false)

    fun setCycleTracking(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_CYCLE_TRACKING, enabled).apply()
    }

    /** Hydration tracking (MVP): an opt-in, on-device-only fluid log with a daily goal + quick-add
     *  buttons. OPT-IN, default OFF (manual-first ethos), the Today "Hydration" card and the detail
     *  feature only appear once this is on. Nothing is synced; the day total lives in the local
     *  metric-series store. */
    const val KEY_HYDRATION_TRACKING = "noop.hydrationTracking"

    fun hydrationTracking(context: Context): Boolean =
        of(context).getBoolean(KEY_HYDRATION_TRACKING, false)

    fun setHydrationTracking(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_HYDRATION_TRACKING, enabled).apply()
    }

    /** "Day-cycle background" (#698): the time-of-day scene (sunrise / day / dusk / night) behind the
     *  Today screen. Default ON, it's the v7 atmosphere. Some people find the moving scene distracting
     *  and want a plain dark canvas, so turning this off makes TodayScreen drop the SceneScreenBackground
     *  and fall back to the flat surface; the cards already sit on an opaque canvas, so they stay just as
     *  readable. Mirrors macOS @AppStorage("noop.showDayCycleBackground"). */
    const val KEY_SHOW_DAY_CYCLE_BACKGROUND = "noop.showDayCycleBackground"

    fun showDayCycleBackground(context: Context): Boolean =
        of(context).getBoolean(KEY_SHOW_DAY_CYCLE_BACKGROUND, true)

    fun setShowDayCycleBackground(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_SHOW_DAY_CYCLE_BACKGROUND, enabled).apply()
    }

    /** Card-surface opacity as a PERCENT (0 = fully see-through, 100 = solid; default 100). Drives the
     *  "Card transparency" setting — every frosted card (Heart Rate, Key Metrics, Recovery Vitals, …)
     *  reads it via [CardAppearance]. Only the glass surface fades; the card content stays readable. */
    const val KEY_CARD_OPACITY = "noop.cardOpacityPercent"

    fun cardOpacityPercent(context: Context): Int =
        of(context).getInt(KEY_CARD_OPACITY, 100).coerceIn(0, 100)

    fun setCardOpacityPercent(context: Context, percent: Int) {
        of(context).edit().putInt(KEY_CARD_OPACITY, percent.coerceIn(0, 100)).apply()
    }

    /** "Sky behind cards" (opt-in, default OFF): extend the day-cycle sky behind the WHOLE Today scroll
     *  (not just the top band) so the Card-transparency slider reveals it under every card. Pairs with
     *  [showDayCycleBackground] — no effect when the scene is off. Read once on Today entry. */
    const val KEY_SKY_BEHIND_CARDS = "noop.skyBehindCards"

    // Default ON: the day-cycle sky extends behind the whole scroll out of the box. Still user-toggleable
    // in Settings ("Sky behind cards"); only never-toggled users pick up the new default. Twin of the iOS
    // @AppStorage(SkyBehindCardsPrefs.enabledKey) defaults.
    fun skyBehindCards(context: Context): Boolean =
        of(context).getBoolean(KEY_SKY_BEHIND_CARDS, true)

    fun setSkyBehindCards(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_SKY_BEHIND_CARDS, enabled).apply()
    }

    /** "Reduce motion in NOOP" (opt-in, default OFF). The literal key matches Apple so the setting has
     *  one cross-platform identity. [rememberQuietMotion] observes it live for every looping surface. */
    const val KEY_QUIET_MOTION = "noop.quietMotion"

    fun quietMotion(context: Context): Boolean =
        of(context).getBoolean(KEY_QUIET_MOTION, false)

    fun setQuietMotion(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_QUIET_MOTION, enabled).apply()
    }

    /** Coach on-device signals (v5): when ON, the opt-in BYO-key Coach's grounding context may include a
     *  SUMMARY-ONLY line of on-device correlations + Lab Book markers (no raw egress). A SECOND opt-in on
     *  top of the existing "let the coach use my data" consent. Default OFF, keeps the anonymity posture. */
    const val KEY_COACH_SIGNALS = "noop.coachSignals"

    fun coachSignals(context: Context): Boolean =
        of(context).getBoolean(KEY_COACH_SIGNALS, false)

    fun setCoachSignals(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_COACH_SIGNALS, enabled).apply()
    }

    /** The user's EDITED Coach system prompt. Empty/absent means "use the built-in default". A small,
     *  non-secret text key, read FRESH per request so an edit takes effect on the next message. Mirrors
     *  macOS/iOS UserDefaults "ai.systemPrompt". */
    const val KEY_COACH_SYSTEM_PROMPT = "noop.coachSystemPrompt"

    /** The stored prompt override, or empty string when nothing custom is set. */
    fun coachSystemPrompt(context: Context): String =
        of(context).getString(KEY_COACH_SYSTEM_PROMPT, "").orEmpty()

    /** Persist [prompt] as the prompt override; a blank value clears it (back to default). */
    fun setCoachSystemPrompt(context: Context, prompt: String) {
        val trimmed = prompt.trim()
        if (trimmed.isEmpty()) of(context).edit().remove(KEY_COACH_SYSTEM_PROMPT).apply()
        else of(context).edit().putString(KEY_COACH_SYSTEM_PROMPT, prompt).apply()
    }

    /** "Auto-detect workouts" (MVP, opt-in, on-device, NON-DESTRUCTIVE). When ON, NOOP scans the last
     *  day or two of strap HR for a sustained-elevated bout and surfaces ONE dismissible Today card
     *  suggesting you save it, it NEVER creates a workout on its own (the user taps Save). Default OFF;
     *  when off no detection runs and no card shows. Mirrors macOS/iOS @AppStorage("autoDetectWorkouts"). */
    const val KEY_AUTO_DETECT_WORKOUTS = "noop.autoDetectWorkouts"

    fun autoDetectWorkouts(context: Context): Boolean =
        of(context).getBoolean(KEY_AUTO_DETECT_WORKOUTS, false)

    fun setAutoDetectWorkouts(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_AUTO_DETECT_WORKOUTS, enabled).apply()
    }

    fun journalReminderEnabled(context: Context): Boolean =
        of(context).getBoolean(KEY_JOURNAL_REMINDER_ENABLED, true)

    fun setJournalReminderEnabled(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_JOURNAL_REMINDER_ENABLED, enabled).apply()
    }

    /** Last local day (ISO yyyy-MM-dd) an illness notification was posted, the once-a-day gate,
     *  persisted so the app-open and background-service call sites can't double-post. */
    const val KEY_ILLNESS_LAST_NOTIFIED_DAY = "noop.illnessLastNotifiedDay"

    fun illnessLastNotifiedDay(context: Context): String? =
        of(context).getString(KEY_ILLNESS_LAST_NOTIFIED_DAY, null)

    fun setIllnessLastNotifiedDay(context: Context, day: String) {
        of(context).edit().putString(KEY_ILLNESS_LAST_NOTIFIED_DAY, day).apply()
    }

    /** Battery alerts, low (≤15%) + charge-complete (100%) strap notifications (#368, thanks @ujix).
     *  Default ON; gated here and behind the OS notification permission. */
    const val KEY_BATTERY_ALERTS = "noop.batteryAlerts"

    fun batteryAlerts(context: Context): Boolean =
        of(context).getBoolean(KEY_BATTERY_ALERTS, true)

    fun setBatteryAlerts(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_BATTERY_ALERTS, enabled).apply()
    }

    /** Predictive "recharge tonight" warning at ~24h of estimated runtime left. Sub-gate under
     *  KEY_BATTERY_ALERTS (both must be on). Default ON so pre-toggle behavior is unchanged.
     *  iOS/macOS twin key: behavior.batteryPredictiveAlerts. */
    const val KEY_BATTERY_PREDICTIVE_ALERTS = "noop.batteryPredictiveAlerts"

    fun predictiveBatteryAlerts(context: Context): Boolean =
        of(context).getBoolean(KEY_BATTERY_PREDICTIVE_ALERTS, true)

    fun setPredictiveBatteryAlerts(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_BATTERY_PREDICTIVE_ALERTS, enabled).apply()
    }

    /** Persisted once-per-crossing flags behind BatteryAlertPolicy, they survive process death so a
     *  battery hovering near a threshold fires exactly once per cycle (low re-arms above 25%, full
     *  re-arms below 100%). */
    const val KEY_BATTERY_LOW_ALERTED = "noop.batteryLowAlerted"
    const val KEY_BATTERY_FULL_ALERTED = "noop.batteryFullAlerted"

    fun batteryLowAlerted(context: Context): Boolean =
        of(context).getBoolean(KEY_BATTERY_LOW_ALERTED, false)

    fun setBatteryLowAlerted(context: Context, alerted: Boolean) {
        of(context).edit().putBoolean(KEY_BATTERY_LOW_ALERTED, alerted).apply()
    }

    fun batteryFullAlerted(context: Context): Boolean =
        of(context).getBoolean(KEY_BATTERY_FULL_ALERTED, false)

    fun setBatteryFullAlerted(context: Context, alerted: Boolean) {
        of(context).edit().putBoolean(KEY_BATTERY_FULL_ALERTED, alerted).apply()
    }

    /** Persisted once-per-discharge gate behind BatteryEstimator.runtimeAlert (the predictive
     *  "~X left" alert; fires ≤24 h, re-arms ≥36 h). Same survive-process-death contract as the
     *  SoC flags above. */
    const val KEY_BATTERY_RUNTIME_ALERTED = "noop.batteryRuntimeAlerted"

    fun batteryRuntimeAlerted(context: Context): Boolean =
        of(context).getBoolean(KEY_BATTERY_RUNTIME_ALERTED, false)

    fun setBatteryRuntimeAlerted(context: Context, alerted: Boolean) {
        of(context).edit().putBoolean(KEY_BATTERY_RUNTIME_ALERTED, alerted).apply()
    }

    /** Persisted gates behind the two ESCALATION alerts. Deliberately separate keys from the low /
     *  runtime flags above: the bug those alerts fix IS the latch, so a `KEY_BATTERY_LOW_ALERTED` or
     *  `KEY_BATTERY_RUNTIME_ALERTED` that is already true must never be able to silence them.
     *  - CRITICAL (BatteryEstimator.criticalAlert): once per discharge cycle, re-arms above 25%.
     *  - BEDTIME (BatteryEstimator.bedtimeAlert): once per NIGHT — it re-arms whenever the pre-bed
     *    window is not open, so it speaks again tomorrow without needing a charge.
     *  iOS/macOS twin keys: behavior.batteryCriticalAlerted / behavior.batteryBedtimeAlerted. */
    const val KEY_BATTERY_CRITICAL_ALERTED = "noop.batteryCriticalAlerted"
    const val KEY_BATTERY_BEDTIME_ALERTED = "noop.batteryBedtimeAlerted"

    fun batteryCriticalAlerted(context: Context): Boolean =
        of(context).getBoolean(KEY_BATTERY_CRITICAL_ALERTED, false)

    fun setBatteryCriticalAlerted(context: Context, alerted: Boolean) {
        of(context).edit().putBoolean(KEY_BATTERY_CRITICAL_ALERTED, alerted).apply()
    }

    fun batteryBedtimeAlerted(context: Context): Boolean =
        of(context).getBoolean(KEY_BATTERY_BEDTIME_ALERTED, false)

    fun setBatteryBedtimeAlerted(context: Context, alerted: Boolean) {
        of(context).edit().putBoolean(KEY_BATTERY_BEDTIME_ALERTED, alerted).apply()
    }

    /** Scheduled report notifications (#517), opt-in, default OFF, no AI. Two independent toggles:
     *  - [KEY_REPORT_MORNING]: a morning recap (Charge + Rest) posted once after a fresh night is
     *    processed. It is NOT alarm-precise, it lands when the next sync + analytics pass completes,
     *    so the copy is honest about timing.
     *  - [KEY_REPORT_WORKOUT]: a post-workout summary (Effort + duration + avg HR) posted when a newly
     *    synced workout is first seen. Same post-sync-timing caveat, a strap-only workout surfaces on
     *    the next history offload, not the instant the session ends.
     *  The dedupe state ([KEY_REPORT_MORNING_DAY] / [KEY_REPORT_LAST_WORKOUT_TS]) survives process death
     *  so the app-open and background call sites can't double-post. Mirrors the BatteryAlert/Illness gate
     *  idiom (a persisted "last fired" marker behind a pure policy object). */
    const val KEY_REPORT_MORNING = "noop.report.morningRecap"
    const val KEY_REPORT_WORKOUT = "noop.report.postWorkout"
    const val KEY_REPORT_MORNING_DAY = "noop.report.lastMorningDay"
    // #593 target-strain nudge: opt-in enable flag + the once-per-day dedupe (last local day it fired).
    const val KEY_REPORT_STRAIN_TARGET = "noop.report.strainTarget"
    const val KEY_REPORT_STRAIN_TARGET_DAY = "noop.report.lastStrainTargetDay"
    const val KEY_REPORT_LAST_WORKOUT_TS = "noop.report.lastWorkoutTs"

    fun morningReportEnabled(context: Context): Boolean =
        of(context).getBoolean(KEY_REPORT_MORNING, false)

    fun setMorningReportEnabled(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_REPORT_MORNING, enabled).apply()
    }

    fun postWorkoutReportEnabled(context: Context): Boolean =
        of(context).getBoolean(KEY_REPORT_WORKOUT, false)

    fun setPostWorkoutReportEnabled(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_REPORT_WORKOUT, enabled).apply()
    }

    /** Last local day (ISO yyyy-MM-dd) the morning recap was posted, the once-a-day gate. */
    fun reportMorningDay(context: Context): String? =
        of(context).getString(KEY_REPORT_MORNING_DAY, null)

    fun setReportMorningDay(context: Context, day: String) {
        of(context).edit().putString(KEY_REPORT_MORNING_DAY, day).apply()
    }

    /** #593: opt-in (default OFF) for the once-a-day optimal-strain-reached nudge. */
    fun strainTargetEnabled(context: Context): Boolean =
        of(context).getBoolean(KEY_REPORT_STRAIN_TARGET, false)

    fun setStrainTargetEnabled(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_REPORT_STRAIN_TARGET, enabled).apply()
    }

    /** Last local day (ISO yyyy-MM-dd) the strain-target nudge was posted, the once-a-day gate. */
    fun reportStrainTargetDay(context: Context): String? =
        of(context).getString(KEY_REPORT_STRAIN_TARGET_DAY, null)

    fun setReportStrainTargetDay(context: Context, day: String) {
        of(context).edit().putString(KEY_REPORT_STRAIN_TARGET_DAY, day).apply()
    }

    /** Start-ts (epoch seconds) of the most recent workout already summarised, only a STRICTLY newer
     *  session fires again, so a re-sync of the same backlog never re-notifies. 0 = none yet. */
    fun reportLastWorkoutTs(context: Context): Long =
        of(context).getLong(KEY_REPORT_LAST_WORKOUT_TS, 0L)

    fun setReportLastWorkoutTs(context: Context, ts: Long) {
        of(context).edit().putLong(KEY_REPORT_LAST_WORKOUT_TS, ts).apply()
    }

    /** Caffeine late-intake nudge (PR#566, mvanhorn), opt-in, default OFF. When on, the Caffeine card
     *  shows a cutoff time (the latest you can have caffeine and still clear it below a target residual by
     *  bedtime) and flags an intake logged after that cutoff. [KEY_CAFFEINE_BEDTIME_MIN] is the user's
     *  bedtime as minutes-since-midnight (default 23:00) the cutoff is computed back from. On-device, no
     *  notification, a quiet inline hint, matching the manual-first caffeine card. */
    const val KEY_CAFFEINE_CUTOFF = "noop.caffeine.cutoffNudge"
    const val KEY_CAFFEINE_BEDTIME_MIN = "noop.caffeine.bedtimeMinutes"

    fun caffeineCutoffEnabled(context: Context): Boolean =
        of(context).getBoolean(KEY_CAFFEINE_CUTOFF, false)

    fun setCaffeineCutoffEnabled(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_CAFFEINE_CUTOFF, enabled).apply()
    }

    /** Bedtime as minutes since midnight the caffeine cutoff is reckoned back from (default 1380 = 23:00). */
    fun caffeineBedtimeMinutes(context: Context): Int =
        of(context).getInt(KEY_CAFFEINE_BEDTIME_MIN, 23 * 60)

    fun setCaffeineBedtimeMinutes(context: Context, minutes: Int) {
        of(context).edit().putInt(KEY_CAFFEINE_BEDTIME_MIN, minutes.coerceIn(0, 24 * 60 - 1)).apply()
    }

    /** Whether the one-shot #313 full-history Effort rescore has run. Set true once it completes so the
     *  on-upgrade pass that regenerates deep-history strain on the 0–100 axis never re-runs. */
    const val KEY_EFFORT_RESCORE_DONE = "noop.effortRescore.v313.done"

    fun effortRescoreDone(context: Context): Boolean =
        of(context).getBoolean(KEY_EFFORT_RESCORE_DONE, false)

    fun setEffortRescoreDone(context: Context) {
        of(context).edit().putBoolean(KEY_EFFORT_RESCORE_DONE, true).apply()
    }

    /** Whether the one-shot #547 implausible-timestamp heal has run. Set true once it completes so the
     *  on-upgrade purge of bad-strap-clock rows (far-past / future-dated) never re-runs. Re-running is
     *  harmless (the deletes are idempotent), but the flag avoids the work on every launch. */
    const val KEY_TS_HEAL_DONE = "noop.tsHeal.v547.done"

    fun tsHealDone(context: Context): Boolean =
        of(context).getBoolean(KEY_TS_HEAL_DONE, false)

    fun setTsHealDone(context: Context) {
        of(context).edit().putBoolean(KEY_TS_HEAL_DONE, true).apply()
    }

    /** #547 RE-POLLUTION re-arm: set true by the BLE layer when a sync's ingest gate dropped implausible
     *  (bad-clock) records, so the next analyze tick re-runs the purge even after [KEY_TS_HEAL_DONE] is set,      *  a wandering-clock strap re-sends bad-dated records across syncs, and may have banked similar garbage
     *  on an OLDER build whose gate was weaker. Cleared once the re-heal runs. */
    const val KEY_TS_HEAL_PENDING = "noop.tsHeal.v547.pending"

    fun tsHealPending(context: Context): Boolean =
        of(context).getBoolean(KEY_TS_HEAL_PENDING, false)

    fun setTsHealPending(context: Context, pending: Boolean) {
        of(context).edit().putBoolean(KEY_TS_HEAL_PENDING, pending).apply()
    }

    /** The last strap we bonded to (address + model), persisted so NOOP can reconnect to it directly on
     *  the next launch, e.g. after an APK update restarts the process (#67). On-device only; never sent. */
    const val KEY_LAST_DEVICE_ADDR = "noop.lastDeviceAddress"
    const val KEY_LAST_DEVICE_MODEL = "noop.lastDeviceModel"

    fun setLastDevice(context: Context, address: String, model: WhoopModel) {
        of(context).edit()
            .putString(KEY_LAST_DEVICE_ADDR, address)
            .putString(KEY_LAST_DEVICE_MODEL, model.name)
            .apply()
    }

    /** The saved strap as (address, model), or null if none has bonded yet. */
    fun lastDevice(context: Context): Pair<String, WhoopModel>? {
        val addr = of(context).getString(KEY_LAST_DEVICE_ADDR, null) ?: return null
        val model = of(context).getString(KEY_LAST_DEVICE_MODEL, null)
            ?.let { name -> runCatching { WhoopModel.valueOf(name) }.getOrNull() }
            ?: WhoopModel.WHOOP4
        return addr to model
    }

    fun clearLastDevice(context: Context) {
        of(context).edit().remove(KEY_LAST_DEVICE_ADDR).remove(KEY_LAST_DEVICE_MODEL).apply()
    }

    /** Wall-clock (unix seconds) of the last history offload that ran to HISTORY_COMPLETE. Persisted
     *  (reimpl of @tavelli's PR #556) so the Live screen's "Last synced N ago" SURVIVES a BLE-client
     *  recreation / process restart and stops reverting to "Never". 0 = never synced on this install. */
    const val KEY_LAST_SYNC_AT = "noop.lastSyncAtSec"

    fun lastSyncAt(context: Context): Long = of(context).getLong(KEY_LAST_SYNC_AT, 0L)

    fun setLastSyncAt(context: Context, epochSec: Long) {
        of(context).edit().putLong(KEY_LAST_SYNC_AT, epochSec).apply()
    }

    /** Last-known strap firmware string, persisted on connect so the debug export can name it OFFLINE
     *  (LiveState.strapFirmware is cleared on disconnect and gone in the scheduled/background export). */
    const val KEY_LAST_FIRMWARE = "noop.lastFirmware"

    fun lastFirmware(context: Context): String? = of(context).getString(KEY_LAST_FIRMWARE, null)

    fun setLastFirmware(context: Context, fw: String?) {
        of(context).edit().apply {
            if (fw.isNullOrBlank()) remove(KEY_LAST_FIRMWARE) else putString(KEY_LAST_FIRMWARE, fw)
        }.apply()
    }
}

/**
 * Root gate around [AppRoot]. Reads the two prefs once, then renders onboarding,
 * the changelog sheet, or just the app shell, updating both the store and local
 * state on each transition.
 */
@Composable
fun NoopRoot() {
    val context = LocalContext.current
    val prefs = remember { NoopPrefs.of(context) }
    val appViewModel: AppViewModel = viewModel()

    // #267: app-wide "came to foreground" hook, mirrors the iOS/macOS scenePhase == .active trigger.
    // requestSync(FOREGROUND) is a safe no-op when nothing's connected/bonded yet (e.g. during
    // onboarding), so this is placed above the onboarding/terms gates rather than duplicated below them.
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(lifecycleOwner, appViewModel) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
                appViewModel.ble.onForeground()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    var onboarded by remember {
        mutableStateOf(prefs.getBoolean(NoopPrefs.KEY_ONBOARDED, false))
    }
    var lastSeenChangelog by remember {
        mutableStateOf(prefs.getString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, "") ?: "")
    }

    // Seed the current What's New into the Updates inbox ONCE per version (idempotent, tracks the last
    // seeded version), for onboarded users only so a brand-new user's first run isn't pre-populated. The
    // bell in the Today header surfaces it; the inbox row deep-links to the full changelog read.
    LaunchedEffect(onboarded) {
        if (onboarded) UpdateStore.from(context).seedWhatsNewIfNeeded()
    }

    // Terms acknowledgment gate, over EVERYTHING (before onboarding/pairing/Bluetooth) until the
    // current terms version is accepted; re-appears if the terms materially change. (clickwrap)
    var acceptedTerms by remember {
        mutableStateOf(prefs.getString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, "") ?: "")
    }
    if (acceptedTerms != Terms.CURRENT_VERSION) {
        TermsGateScreen(onAccept = {
            prefs.edit()
                .putString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, Terms.CURRENT_VERSION)
                .putString(NoopPrefs.KEY_ACCEPTED_TERMS_AT, java.time.Instant.now().toString())
                .apply()
            acceptedTerms = Terms.CURRENT_VERSION
        })
        return
    }

    if (!onboarded) {
        OnboardingScreen(
            viewModel = appViewModel,
            onFinished = {
                // A brand-new user just saw the expectations in onboarding, don't also pop the
                // changelog at them; mark them current (mirrors macOS ContentView onFinished).
                prefs.edit()
                    .putBoolean(NoopPrefs.KEY_ONBOARDED, true)
                    .putString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, AppChangelog.CURRENT_VERSION)
                    .apply()
                lastSeenChangelog = AppChangelog.CURRENT_VERSION
                onboarded = true
            },
        )
        return
    }

    // Existing, onboarded user: render the app, and if they've updated since last launch
    // (stored version behind current), show "What's New" once over the top.
    AppRoot(viewModel = appViewModel)

    if (lastSeenChangelog != AppChangelog.CURRENT_VERSION) {
        Dialog(
            onDismissRequest = {
                prefs.edit()
                    .putString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, AppChangelog.CURRENT_VERSION)
                    .apply()
                lastSeenChangelog = AppChangelog.CURRENT_VERSION
            },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                WhatsNewSheet(
                    onClose = {
                        prefs.edit()
                            .putString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, AppChangelog.CURRENT_VERSION)
                            .apply()
                        lastSeenChangelog = AppChangelog.CURRENT_VERSION
                    },
                )
            }
        }
    }
}
