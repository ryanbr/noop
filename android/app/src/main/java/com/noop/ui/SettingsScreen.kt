package com.noop.ui

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Brightness6
import androidx.compose.material.icons.filled.Campaign
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.SaveAlt
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.Vibration
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.BuildConfig
import com.noop.analytics.Baselines
import com.noop.analytics.Zones
import com.noop.R
import com.noop.ble.PuffinExperiment
import com.noop.ble.WhoopBleClient
// #174: the R22 card reads the flag COUNT off Whoop5Config.enableR22Sequence rather than restating it —
// the hardcoded "15" outlived the sequence growing to 16 and declared success a flag early.
import com.noop.protocol.Whoop5Config
import com.noop.protocol.EcgRawDataGateReport
import com.noop.ble.WhoopModel
import com.noop.data.DataBackup
import com.noop.ingest.RawSensorExport
import com.noop.ingest.WhoopCsvExporter
import com.noop.update.UpdateCheck
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

// MARK: - Settings (ported from Strand/Screens/SettingsView.swift)
//
// Profile (the numbers that power HR zones / calories / recovery baselines), a
// Backup & restore section wiring DataBackup export/import through the Storage
// Access Framework, and an About section with version + attribution + a Support
// link. Re-skinned to the locked NOOP component system: every surface is a
// NoopCard, every status uses StatePill, the two-column form feel is preserved.
//
// macOS parity notes:
//  - macOS persisted the profile in a ProfileStore (ObservableObject on disk). The
//    Android equivalent is SharedPreferences; this screen owns the only profile
//    store in the app, so HealthScreen's age-agnostic HR-max default can later read
//    from it. Values persist immediately on every change.
//  - macOS used native +/- Steppers; Compose has no Stepper, so each numeric field
//    is a tabular value flanked by round −/+ buttons (same intent, same ranges).
//  - The strap "Re-scan / Disconnect" controls map to the ViewModel's connect() /
//    disconnect() pass-throughs.
//  - Backup export/import run through SAF (CreateDocument / OpenDocument); the macOS
//    alert is mirrored by a Toast. DataBackup.exportTo already checkpoints the WAL,
//    so no separate repo checkpoint call is needed.

// MARK: - Profile store (SharedPreferences-backed; the macOS ProfileStore equivalent)

/**
 * The user's body profile — age / sex / weight / height plus an optional manual
 * HR-max override. Persisted to SharedPreferences so the values survive restarts
 * and other screens (HealthScreen, Coach zones) can read the same source of truth.
 *
 * Mirrors the macOS `ProfileStore` fields and ranges exactly. `hrMaxOverride == 0`
 * means "auto" — fall back to the Tanaka estimate from [age].
 */
class ProfileStore(private val prefs: SharedPreferences) {

    /**
     * Current age in whole years (#146), DERIVED from [dateOfBirthMillis] so it advances on its own
     * instead of going stale until the user bumps a number. Read-only; change age via [setAge] (the
     * +/- stepper) or [dateOfBirthMillis] directly. Every existing reader (Fitness Age / Vitality /
     * Tanaka) keeps reading `profile.age` unchanged.
     */
    val age: Int
        get() = yearsFromDob(dateOfBirthMillis).coerceIn(AGE_MIN, AGE_MAX)

    /**
     * Date of birth as epoch millis — the canonical source of truth for [age] (#146). The getter
     * lazily migrates a pre-#146 stored age (or a restored legacy `age`, see [applyBackup]) into an
     * anchored DOB the first time it's read, then persists it so the derivation is stable. The setter
     * mirrors the derived Int age under the legacy [KEY_AGE] so the `.noopbak` backup whitelist keeps
     * exporting an age with no change to the cross-platform contract.
     */
    var dateOfBirthMillis: Long
        get() {
            if (prefs.contains(KEY_DOB)) return prefs.getLong(KEY_DOB, 0L)
            val legacyAge = (if (prefs.contains(KEY_AGE)) prefs.getInt(KEY_AGE, 30) else 30)
                .coerceIn(AGE_MIN, AGE_MAX)
            val dob = dobForAge(legacyAge)
            prefs.edit().putLong(KEY_DOB, dob).putInt(KEY_AGE, legacyAge).apply()
            return dob
        }
        set(v) = prefs.edit()
            .putLong(KEY_DOB, v)
            .putInt(KEY_AGE, yearsFromDob(v).coerceIn(AGE_MIN, AGE_MAX))
            .apply()

    /** Set age by anchoring a date of birth `years` before today (the +/- stepper and backup restore
     *  both go through here, so age always flows from a DOB). Clamped to [AGE_MIN]..[AGE_MAX]. */
    fun setAge(years: Int) { dateOfBirthMillis = dobForAge(years.coerceIn(AGE_MIN, AGE_MAX)) }

    /** "male" | "female" | "nonbinary" — matches the macOS tag values. */
    var sex: String
        get() = prefs.getString(KEY_SEX, "male") ?: "male"
        set(v) = prefs.edit().putString(KEY_SEX, v).apply()

    var weightKg: Double
        get() = prefs.getFloat(KEY_WEIGHT, 75f).toDouble().coerceIn(WEIGHT_MIN, WEIGHT_MAX)
        set(v) = prefs.edit().putFloat(KEY_WEIGHT, v.coerceIn(WEIGHT_MIN, WEIGHT_MAX).toFloat()).apply()

    var heightCm: Double
        get() = prefs.getFloat(KEY_HEIGHT, 178f).toDouble().coerceIn(HEIGHT_MIN, HEIGHT_MAX)
        set(v) = prefs.edit().putFloat(KEY_HEIGHT, v.coerceIn(HEIGHT_MIN, HEIGHT_MAX).toFloat()).apply()

    /**
     * Waist circumference in cm; 0 = unset (the Fitness Age VO₂max estimate is hidden until a waist
     * is entered). Optional — it only unlocks the VO₂max read-out and never moves the headline Fitness
     * Age (the engine's body term cancels). No coercion floor (0 has to remain a sentinel for "unset");
     * the upper bound is clamped so a fat-fingered entry can't run away.
     */
    var waistCm: Double
        get() = prefs.getFloat(KEY_WAIST, 0f).toDouble().coerceIn(0.0, WAIST_MAX)
        set(v) = prefs.edit().putFloat(KEY_WAIST, v.coerceIn(0.0, WAIST_MAX).toFloat()).apply()

    /** Manual max-heart-rate override in bpm; 0 = automatic (Tanaka). */
    var hrMaxOverride: Int
        get() = prefs.getInt(KEY_HRMAX, 0).coerceIn(0, 230)
        set(v) = prefs.edit().putInt(KEY_HRMAX, v.coerceIn(0, 230)).apply()

    /**
     * Step-calibration divisor (#139/#132): counter ticks per real step for the @57 motion
     * counter. 1.0 = raw pass-through (default — no behavior change). Clamped 0.5–30.0
     * (WHOOP 5/MG motion-counter overcount can reach ~24×, so the ceiling has to be high).
     */
    var stepTicksPerStep: Double
        get() = prefs.getFloat(KEY_STEP_SCALE, 1f).toDouble().coerceIn(STEP_SCALE_MIN, STEP_SCALE_MAX)
        set(v) = prefs.edit()
            .putFloat(KEY_STEP_SCALE, v.coerceIn(STEP_SCALE_MIN, STEP_SCALE_MAX).toFloat())
            .apply()

    // ── Steps ESTIMATE calibration (WHOOP 4.0; StepsEstimateEngine) ─────────────────────────────
    // Mirror of the macOS ProfileStore fields: the engine writes the auto-fit each analytics pass and
    // the Settings/Steps screen reads them. [stepsManualCoefficient] is the ONLY user-settable field
    // (0 = auto-fit / null to the engine; > 0 = manual override fed into calibrate()); the other three
    // are fitted outputs surfaced read-only.
    /** Fitted (or manually-set) steps-per-unit-of-motion coefficient last persisted by the engine. */
    var stepsCalibrationCoefficient: Double
        get() = prefs.getFloat(KEY_STEPS_COEFF, 0f).toDouble()
        set(v) = prefs.edit().putFloat(KEY_STEPS_COEFF, v.toFloat()).apply()

    /** How many calibration days fed the last auto-fit (0 when purely manual / not yet fit). */
    var stepsCalibrationSampleDays: Int
        get() = prefs.getInt(KEY_STEPS_SAMPLE_DAYS, 0)
        set(v) = prefs.edit().putInt(KEY_STEPS_SAMPLE_DAYS, v).apply()

    /** 0–1 trust in the last fit (1.0 for a manual coefficient). */
    var stepsCalibrationConfidence: Double
        get() = prefs.getFloat(KEY_STEPS_CONFIDENCE, 0f).toDouble()
        set(v) = prefs.edit().putFloat(KEY_STEPS_CONFIDENCE, v.toFloat()).apply()

    /** True when the persisted coefficient came from the user's manual override, not an auto-fit. */
    var stepsCalibrationManual: Boolean
        get() = prefs.getBoolean(KEY_STEPS_MANUAL_FLAG, false)
        set(v) = prefs.edit().putBoolean(KEY_STEPS_MANUAL_FLAG, v).apply()

    /** User-set manual coefficient. 0 = auto-fit (null to the engine); > 0 = manual override. */
    var stepsManualCoefficient: Double
        get() = prefs.getFloat(KEY_STEPS_MANUAL_COEFF, 0f).toDouble().coerceAtLeast(0.0)
        set(v) = prefs.edit().putFloat(KEY_STEPS_MANUAL_COEFF, v.coerceAtLeast(0.0).toFloat()).apply()

    /** The manual override to feed into `StepsEstimateEngine.calibrate(points, manualOverride)`:
     *  null when 0 (auto-fit), the positive value otherwise. */
    val stepsManualOverride: Double? get() = stepsManualCoefficient.takeIf { it > 0 }

    /** The auto (Tanaka) HR-max for the current age. */
    val hrMaxAuto: Int get() = Zones.hrMaxTanaka(age)

    /** Effective HR-max: the manual override if set, else the Tanaka estimate. */
    val hrMax: Int get() = if (hrMaxOverride > 0) hrMaxOverride else hrMaxAuto

    // ── Backup settings snapshot/apply (#1000) ──────────────────────────────────────────────────
    // The profile half of a `.noopbak`'s `settings.json`. Canonical key strings mirror
    // `BackupSettingsCodec.WHITELIST` (and the Apple `BackupSettings.whitelist`) exactly — note
    // canonical `profile.hrMax` maps onto this store's `hr_max_override` pref. Lives on ProfileStore
    // because only it knows its private pref keys; `contains` checks keep never-set fields OUT of the
    // snapshot so restoring on another device doesn't stamp defaults over that device's real values.

    /** The user-SET profile fields, keyed canonically, for the backup exporter. */
    fun backupSnapshot(): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        // #146: age is now derived from a DOB; export the current derived Int under the legacy
        // `profile.age` key (the whitelist carries an Int, not a Date). A never-touched profile
        // (neither key set) still stays out of the snapshot.
        if (prefs.contains(KEY_DOB) || prefs.contains(KEY_AGE)) out["profile.age"] = age
        if (prefs.contains(KEY_SEX)) out["profile.sex"] = sex
        if (prefs.contains(KEY_WEIGHT)) out["profile.weightKg"] = weightKg
        if (prefs.contains(KEY_HEIGHT)) out["profile.heightCm"] = heightCm
        if (prefs.contains(KEY_WAIST)) out["profile.waistCm"] = waistCm
        if (prefs.contains(KEY_HRMAX)) out["profile.hrMax"] = hrMaxOverride
        return out
    }

    /**
     * Apply a restored backup's profile fields (canonical keys, already whitelist-filtered by
     * `BackupSettingsCodec.decode`). Missing keys leave the current values alone; every write goes
     * through the property setters, so the usual range clamps apply.
     */
    fun applyBackup(values: Map<String, Any>) {
        // #146: a restore carries only an Int age. Route it through setAge so the restored age
        // re-anchors this device's DOB (clearing any stale local DOB) and then advances on its own —
        // the deterministic twin of the Apple side clearing `profile.dateOfBirth` on apply.
        (values["profile.age"] as? Number)?.let { setAge(it.toInt()) }
        (values["profile.sex"] as? String)?.let { sex = it }
        (values["profile.weightKg"] as? Number)?.let { weightKg = it.toDouble() }
        (values["profile.heightCm"] as? Number)?.let { heightCm = it.toDouble() }
        (values["profile.waistCm"] as? Number)?.let { waistCm = it.toDouble() }
        (values["profile.hrMax"] as? Number)?.let { hrMaxOverride = it.toInt() }
    }

    companion object {
        private const val PREFS = "noop_profile"
        /** Date of birth as epoch millis — the #146 source of truth for [age]. */
        private const val KEY_DOB = "date_of_birth"
        /** Pre-#146 age key, now kept mirrored from the DOB so the `.noopbak` whitelist (Int age)
         *  keeps round-tripping unchanged. */
        private const val KEY_AGE = "age"
        private const val KEY_SEX = "sex"
        private const val KEY_WEIGHT = "weight_kg"
        private const val KEY_HEIGHT = "height_cm"
        private const val KEY_WAIST = "waist_cm"
        private const val KEY_HRMAX = "hr_max_override"
        private const val KEY_STEP_SCALE = "step_ticks_per_step"
        private const val KEY_STEPS_COEFF = "steps_calibration_coefficient"
        private const val KEY_STEPS_SAMPLE_DAYS = "steps_calibration_sample_days"
        private const val KEY_STEPS_CONFIDENCE = "steps_calibration_confidence"
        private const val KEY_STEPS_MANUAL_FLAG = "steps_calibration_manual"
        private const val KEY_STEPS_MANUAL_COEFF = "steps_manual_coefficient"

        private const val AGE_MIN = 13
        private const val AGE_MAX = 100
        private const val WEIGHT_MIN = 30.0
        private const val WEIGHT_MAX = 250.0
        private const val HEIGHT_MIN = 120.0
        private const val HEIGHT_MAX = 230.0
        private const val WAIST_MAX = 200.0
        private const val STEP_SCALE_MIN = 0.5
        private const val STEP_SCALE_MAX = 30.0

        /**
         * Variable step for the calibration stepper so high values stay reachable: fine near the
         * 1.0 default (where most people land), coarse up at the 20s+ a 5/MG needs. A flat 0.1 step
         * from 0.5 to 30 would be ~295 taps — unusable. Mirrors macOS `ProfileStore.stepScaleIncrement`.
         *  - `< 2.0` → 0.1   (precision around the default)
         *  - `2.0–5.0` → 0.5
         *  - `>= 5.0` → 1.0   (ballpark the ~24× overcount in ~19 taps)
         */
        fun stepScaleIncrement(value: Double): Double = when {
            value < 2.0 -> 0.1
            value < 5.0 -> 0.5
            else -> 1.0
        }

        // ── #146 age <-> date-of-birth ──────────────────────────────────────────────────────────
        /** Whole years between the DOB and today (floor — a birthday not yet reached doesn't count).
         *  Uses the device's default zone so the rollover matches the user's local calendar. Mirrors
         *  the Apple `ProfileStore.years(from:to:)`. */
        fun yearsFromDob(dobMillis: Long): Int {
            val zone = java.time.ZoneId.systemDefault()
            val dob = java.time.Instant.ofEpochMilli(dobMillis).atZone(zone).toLocalDate()
            return java.time.temporal.ChronoUnit.YEARS.between(dob, java.time.LocalDate.now(zone)).toInt()
        }

        /** A date of birth `age` whole years before today (anchored to today's month/day, so the
         *  derived age is exactly `age`). Mirrors the Apple `ProfileStore.dateOfBirth(forAge:)`. */
        fun dobForAge(age: Int): Long {
            val zone = java.time.ZoneId.systemDefault()
            return java.time.LocalDate.now(zone).minusYears(age.toLong())
                .atStartOfDay(zone).toInstant().toEpochMilli()
        }

        /**
         * One increment/decrement of the calibration divisor, snapped to the increment grid and
         * clamped to [STEP_SCALE_MIN]..[STEP_SCALE_MAX]. Decrement uses the increment for the
         * *target* band so the up/down sequence is symmetric at band boundaries (e.g. 5.0 −1 → 4.0,
         * 4.0 +0.5 → 4.5). Mirrors macOS `ProfileStore.steppedStepScale`.
         */
        fun steppedStepScale(value: Double, up: Boolean): Double {
            val delta = if (up) stepScaleIncrement(value) else stepScaleIncrement(value - 0.0001)
            val next = Math.round((value + if (up) delta else -delta) / delta) * delta
            return next.coerceIn(STEP_SCALE_MIN, STEP_SCALE_MAX)
        }

        fun from(context: Context): ProfileStore =
            ProfileStore(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}

// MARK: - Screen

@Composable
fun SettingsScreen(
    vm: AppViewModel,
    onOpenTestCentre: () -> Unit = {},
    onOpenBackupSync: () -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val live by vm.live.collectAsStateWithLifecycle()

    // The profile store is stable for the lifetime of this screen; a version counter
    // forces recomposition after each mutating write (SharedPreferences isn't reactive).
    val profile = remember { ProfileStore.from(context) }
    var rev by remember { mutableStateOf(0) }
    fun mutate(block: () -> Unit) { block(); rev++ }

    // #820 made a BLE callback a writer of `noop_experiments`: a strap FAMILY switch clears the
    // 5/MG-only probes. Without this the toggles below would keep showing their old state until you
    // navigated away and back, because an unkeyed remember{} reads once per composition. macOS gets
    // this free — @AppStorage republishes on any UserDefaults write — and Compose needs it spelled
    // out. Bumping `rev` is the whole mechanism; the four reads are keyed on it.
    DisposableEffect(Unit) {
        val expPrefs = context.getSharedPreferences(PuffinExperiment.PREFS, Context.MODE_PRIVATE)
        // Strong local for the effect's lifetime: Android holds these listeners WEAKLY, so one that is
        // only referenced by the register call gets collected and silently stops firing.
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            // `key` is @Nullable on modern SDKs — it arrives null when the whole file is cleared — so
            // the null check is required to compile, not just defensive. A clear() is not something
            // this app does, but treating it as "everything changed" is the correct reading anyway.
            if (key == null || key in PuffinExperiment.FIVE_MG_GATED_KEYS) rev++
        }
        expPrefs.registerOnSharedPreferenceChangeListener(listener)
        onDispose { expPrefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }

    var backupBusy by remember { mutableStateOf(false) }

    // #646/#651: LogExport's zip build + file read now run on Dispatchers.IO instead of blocking the
    // caller, so these buttons no longer freeze the UI — but nothing else stopped a second tap mid-export
    // either. A big raw capture is exactly when someone taps twice, firing two zips / two chooser
    // intents. Same disable-while-busy + spinner shape as backupBusy above, one flag per button.
    // Each clears in a `finally`, not after the call: they only cleared correctly before because every
    // LogExport entry point happens to wrap its body in runCatching. The guard should not depend on a
    // callee's error handling - a throw would strand the button disabled behind a spinner that never
    // stops, with no way back short of leaving the screen.
    var strapLogBusy by remember { mutableStateOf(false) }
    var whoop5CaptureBusy by remember { mutableStateOf(false) }
    var rawAndLogBusy by remember { mutableStateOf(false) }

    // Re-scan must request the runtime Bluetooth permission before scanning — without this the
    // button calls connect() directly and silently no-ops on Android 12+ when the permission was
    // denied/revoked (issue #1). Shared with Live's Connect via the one rememberRequestScan gate.
    val requestScan = rememberRequestScan { vm.connect() }

    // "What's New" changelog sheet, reachable any time from About (mirrors the macOS
    // Settings → About "What's new" button). Persistence/gating lives in NoopRoot; this
    // is a manual re-open and writes nothing.
    var showWhatsNew by remember { mutableStateOf(false) }

    // "How your scores work" explainer sheet, reachable any time from About (macOS/iOS parity).
    var showScoringGuide by remember { mutableStateOf(false) }

    // "How NOOP works" primer sheet (COMPONENT 5 of the explainability layer), reachable any time
    // from About — the plain-English tour of sleep sorting, scores, recording and provenance.
    var showHowNoopWorks by remember { mutableStateOf(false) }

    // "WHOOP 4.0 vs 5.0/MG: what each can read and why" explainer (FI-2 / #490), reachable from the
    // Strap section by BOTH model owners. Clears up which features each strap supports — e.g. why the
    // strap-firmware broadcast-out is 5/MG-only while NOOP's own re-broadcast works on any strap.
    var showModelComparison by remember { mutableStateOf(false) }

    // "Recalibrate Charge baseline" confirm dialog (Charge advanced). Writes now-seconds to BOTH the
    // noop.hrvBaselineEpoch and noop.recoveryBaselineEpoch prefs so foldHistory re-seeds every baseline
    // that feeds Charge from tonight onward; the standing analyze loop picks it up on its next pass.
    // Fixes a baseline poisoned by a bad first week (worn sick, or early nights that anchored too high).
    var showRecalibrateConfirm by remember { mutableStateOf(false) }

    // Steps-estimate calibration screen (WHOOP 4.0), reached from the Profile card's "Steps estimate"
    // tap-through. Mirrors the macOS StepsCalibrationSheet: honest explainer + current fit + a recent
    // estimated-vs-phone table + a manual coefficient override. Full-screen Dialog like the guide above.
    var showStepsCalibration by remember { mutableStateOf(false) }

    // Whether the "Advanced" disclosure (experimental probes, diagnostics, raw-sensor export, Trends
    // report) is expanded. Default FALSE so a first-run user lands on the everyday sections instead of
    // the full wall of cards (S3); nothing is removed, every section stays one tap away by expanding.
    // Persisted to the same key the iOS @AppStorage uses ("noop.settingsAdvancedOpen"); SharedPreferences
    // isn't reactive, so the Switch-style toggle drives a local state that writes straight through.
    var advancedOpen by remember {
        mutableStateOf(SettingsDisclosurePrefs.read(NoopPrefs.of(context)))
    }

    // EXPERIMENTAL WHOOP 5/MG protocol probes (off by default). Mirrors the macOS @AppStorage toggle;
    // SharedPreferences isn't reactive, so the Switch drives a local mutableState that the store reads.
    val puffinExperiment = remember { PuffinExperiment.from(context) }
    var puffinExperiments by remember(rev) { mutableStateOf(puffinExperiment.isEnabled) }
    var puffinCapture by remember(rev) { mutableStateOf(puffinExperiment.isCaptureEnabled) }
    var deepData by remember(rev) { mutableStateOf(puffinExperiment.isDeepDataEnabled) }

    // #174: set when the deep-data switch is turned OFF, so the app can OFFER to clear the flags on the
    // strap instead of silently leaving them set. The switch alone has never written anything in either
    // direction — it gates sends — so turning it off used to change nothing on the hardware while reading
    // like an undo. Asking is the right shape rather than writing automatically: the strap may not be
    // connected, and a write to bonded hardware is not something a toggle should do unannounced.
    var confirmingDeepDataDisable by remember { mutableStateOf(false) }
    val r22DisableReport by vm.ble.r22DisableReport.collectAsState()
    // How many flags the enable sequence actually writes. Read from the sequence rather than restated, so
    // the card cannot drift from it again — it said "15" for the whole life of the 16-flag sequence.
    val r22FlagCount = Whoop5Config.enableR22Sequence.size
    var broadcastHr by remember(rev) { mutableStateOf(puffinExperiment.broadcastHr) }
    // ECG raw-data gate (#891): the opt-in, the write result, and the attested-MG gate the buttons need.
    var ecgRawData by remember(rev) { mutableStateOf(puffinExperiment.ecgRawData) }
    val ecgGateReport by vm.ble.ecgRawDataGate.collectAsStateWithLifecycle()
    val ecgVariant by vm.ble.whoop5VariantFlow.collectAsStateWithLifecycle()
    val ecgVariantIsMG = ecgVariant.isMG
    // "Sleep staging (V2)" — V2 is the DEFAULT for every strap (WHOOP 4 and 5/MG); turn it OFF to fall back
    // to V1. Model-agnostic, so it lives outside the 5/MG-only card. 4.0 is unvalidated either way (#319/#347).
    var experimentalSleepV2 by remember { mutableStateOf(puffinExperiment.experimentalSleepV2) }
    // "Motion-aware wake refinement" (#364 follow-up) — OFF by default. Self-gates on observed gravity +
    // step density, so it is a no-op on a sparse (e.g. WHOOP 4.0) night regardless of this switch.
    var motionAwareWake by remember { mutableStateOf(puffinExperiment.motionAwareWake) }

    // Whether to surface the WHOOP 5/MG-only probes (puffin / R22 / broadcast-HR / frame-capture). Gated
    // so a confident 4.0 owner never sees 5/MG controls that can't touch their strap (#22). The model
    // preference DEFAULTS to WHOOP4, so we deliberately do NOT hide on the raw default alone — the same
    // "noop.selectedWhoopModel" key is rewritten to the family that actually advertised when a strap
    // connects (WhoopBleClient.persistSelectedModel, PR#195), so a real 5/MG owner who never opened the
    // model picker still flips this true once their strap is discovered. We also show it whenever a 5/MG
    // is live-detected this session. Hide only when the user is confidently on a 4.0 (pref says WHOOP4
    // AND nothing 5/MG is connected). Mirrors the macOS SettingsView `showFiveMGControls` gate.
    val selectedModelName = remember(rev) {
        context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE)
            .getString("noop.selectedWhoopModel", null)
    }
    val showFiveMGControls = selectedModelName == WhoopModel.WHOOP5_MG.name || live.whoop5Detected

    // "Keep connected in the background" — drives WhoopConnectionService (foreground service). Default
    // on. SharedPreferences isn't reactive, so the Switch mirrors into a local state.
    var backgroundConnection by remember { mutableStateOf(NoopPrefs.backgroundConnection(context)) }
    var fastHistorySync by remember { mutableStateOf(NoopPrefs.fastHistorySync(context)) }
    var fastLinkPhy by remember { mutableStateOf(NoopPrefs.fastLinkPhy(context)) }

    // "Continuous HRV capture" — hold the dense realtime stream armed 24/7 (better overnight HRV) at the
    // cost of more battery. Default OFF; only does anything with background connection on. Local mirror.
    var continuousHrv by remember { mutableStateOf(NoopPrefs.continuousHrv(context)) }

    // "Overnight only" (#927): arm the continuous stream only inside the nightly quiet-hours window
    // instead of 24/7. Defaults ON for fresh installs (#1008); existing installs are pinned to OFF by
    // NoopPrefs.migrateContinuousHrvOvernightDefault() at launch, so they keep always-on. Local mirror,
    // read through NoopPrefs so it cannot disagree with what the BLE client acts on.
    var continuousHrvOvernight by remember { mutableStateOf(NoopPrefs.continuousHrvOvernight(context)) }

    // #477 Power saving: battery-adaptive strap-sync cadence + optional HRV-capture pause. Local mirrors.
    var powerSaving by remember { mutableStateOf(NoopPrefs.powerSaving(context)) }
    var powerSavingBatteryPct by remember { mutableStateOf(NoopPrefs.powerSavingBatteryPct(context)) }
    var pauseHrvOnPowerSave by remember { mutableStateOf(NoopPrefs.pauseHrvOnPowerSave(context)) }

    // --- v5 Health & wellness toggle group. All SharedPreferences-backed (not reactive), so each Switch
    // drives a local mirror that writes straight through to the same keys the v5 engine readers use.
    // Illness watch routes through the ViewModel so the banner recomputes live; the rest are pref writes
    // the engines pick up on the next analytics pass / offload. All opt-in / safe-default per spec.
    var illnessWatch by remember { mutableStateOf(NoopPrefs.illnessWatch(context)) }
    var cycleTracking by remember { mutableStateOf(NoopPrefs.cycleTracking(context)) }
    var hydrationTracking by remember { mutableStateOf(NoopPrefs.hydrationTracking(context)) }
    var stressCheckIn by remember { mutableStateOf(BiofeedbackPrefs.checkInEnabled(context)) }
    var stressAutoNudge by remember { mutableStateOf(BiofeedbackPrefs.autoNudge(context)) }
    var rhythmEnabled by remember { mutableStateOf(RhythmConsent.isEnabled(context)) }
    var coachSignals by remember { mutableStateOf(NoopPrefs.coachSignals(context)) }
    var autoDetectWorkouts by remember { mutableStateOf(NoopPrefs.autoDetectWorkouts(context)) }
    var journalReminder by remember { mutableStateOf(NoopPrefs.journalReminderEnabled(context)) }
    // Keep the screen on during a manual workout recording (#703), default OFF. The live-workout
    // screen reads this same "workoutKeepScreenOn" key. String shared verbatim with the iOS/Mac twin
    // (AppStorage "workoutKeepScreenOn"). Read/written inline against the shared prefs store.
    var workoutKeepScreenOn by remember {
        mutableStateOf(NoopPrefs.of(context).getBoolean("workoutKeepScreenOn", false))
    }
    // Live Sessions (beta) — gates the Today "Start session" entry. Unlike its section-mates this is a
    // BETA feature flag, default ON (`live_sessions_beta`, see LiveSessionPrefs); off hides the entry.
    var liveSessionsBeta by remember { mutableStateOf(LiveSessionPrefs.enabled(context)) }

    // Imperial/Metric display preference (D#103). Display-only — stored data stays SI. The system drives
    // the profile fields below (imperial entry) too, so it's local state the whole screen reads.
    // `temperatureRaw` is "" (match the system) or a TemperatureUnit raw value. SharedPreferences isn't
    // reactive, so these mirror into local state like the toggles above.
    var unitSystem by remember { mutableStateOf(UnitPrefs.system(context)) }
    var temperatureRaw by remember {
        mutableStateOf(NoopPrefs.of(context).getString(NoopPrefs.KEY_TEMPERATURE_UNIT, "") ?: "")
    }
    // Effort display scale (#268) — show NOOP's native 0–100 Effort or WHOOP's 0–21 Day Strain axis.
    // Display-only; the stored value never changes. Mirrors into local state like the toggles above.
    var effortScale by remember { mutableStateOf(UnitPrefs.effortScale(context)) }

    // App icon (v3 "Titanium & Gold") — machined-titanium (.IconDefault) or blued-titanium (.IconNavy).
    // SharedPreferences isn't reactive, so the segmented control drives this local mirror; flipping it
    // enables exactly one launcher alias via PackageManager (see setAppIcon below).
    var appIconNavy by remember { mutableStateOf(NoopPrefs.appIconNavy(context)) }

    // Theme (System / Light / Dark) — drives NoopTheme; AppearancePrefs mirrors it in snapshot state.
    var themeMode by remember { mutableStateOf(AppearancePrefs.mode) }
    // Chart colours (Titanium / Classic) — re-colours gauges + charts; ChartStylePrefs mirrors it live.
    var chartStyle by remember { mutableStateOf(ChartStylePrefs.style) }
    // Chrome accent (Mint / WHOOP Blue / Custom) — chrome only; AccentPrefs mirrors it in snapshot state.
    var accentColor by remember { mutableStateOf(AccentPrefs.color) }
    var accentCustomHex by remember { mutableStateOf(AccentPrefs.customHex) }
    // Trend charts (Line / Bar) — flips the Trends tab between the gradient line and value-ramp bars.
    // Display-only; SharedPreferences isn't reactive, so mirror into local state and persist on select.
    var trendChartStyle by remember { mutableStateOf(UnitPrefs.trendChartStyle(context)) }
    var sleepChartStyle by remember { mutableStateOf(UnitPrefs.sleepChartStyle(context)) }
    // In-app quiet motion (#941), default OFF. The process-wide preference observer in NoopMotion makes
    // this take effect on every currently composed looping surface as soon as the switch is flipped.
    var quietMotion by remember { mutableStateOf(NoopPrefs.quietMotion(context)) }
    // HRV window (#141) — whole-night vs deep-sleep (WHOOP-style). NOT display-only: it changes the computed
    // avgHrv, so a switch clears the analyze watermark to force a re-score + re-baseline on the next pass.
    var hrvWindow by remember { mutableStateOf(UnitPrefs.hrvWindow(context)) }
    // Day-cycle background (#698) — the time-of-day scene behind Today. Default ON. SharedPreferences
    // isn't reactive, so the Switch mirrors into local state; TodayScreen reads the same pref on entry.
    var showDayCycleBackground by remember { mutableStateOf(NoopPrefs.showDayCycleBackground(context)) }
    // "Sky behind cards" (opt-in, default OFF) — extend the day-cycle sky behind the whole Today scroll so
    // Card transparency reveals it under every card. Mirrors into local state; TodayScreen reads on entry.
    var skyBehindCards by remember { mutableStateOf(NoopPrefs.skyBehindCards(context)) }
    // Card-surface opacity (0f = clear, 1f = solid), for the "Card transparency" slider. Live-previews via
    // CardAppearance; saved on release.
    var cardOpacity by remember { mutableStateOf(NoopPrefs.cardOpacityPercent(context) / 100f) }

    // SAF launchers — CreateDocument for export, OpenDocument for import.
    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip"),
    ) { uri ->
        if (uri == null) { backupBusy = false; return@rememberLauncherForActivityResult }
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { DataBackup.exportTo(context, uri) }
            }
            backupBusy = false
            result.fold(
                onSuccess = {
                    Toast.makeText(
                        context,
                        "Backup exported. Copy this file to your new phone and use Import there to restore everything.",
                        Toast.LENGTH_LONG,
                    ).show()
                },
                onFailure = { e ->
                    Toast.makeText(context, "Backup problem: ${e.message}", Toast.LENGTH_LONG).show()
                },
            )
        }
    }

    // CSV export — the 4-CSV WHOOP-format zip NOOP's own importers re-import (Android + Mac).
    val csvExportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip"),
    ) { uri ->
        if (uri == null) { backupBusy = false; return@rememberLauncherForActivityResult }
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                // #458: thread the registry's ACTIVE strap id — the exporter's old "my-whoop" default
                // exported an empty zip on live-BLE installs (the engine banks under "<strapId>-noop").
                runCatching { WhoopCsvExporter.exportZip(context, uri, vm.repo, vm.activeStrapId) }
            }
            backupBusy = false
            result.fold(
                onSuccess = { msg ->
                    Toast.makeText(
                        context,
                        "$msg Re-import it via Data sources → WHOOP import, on Android or Mac.",
                        Toast.LENGTH_LONG,
                    ).show()
                },
                onFailure = { e ->
                    Toast.makeText(context, "CSV export problem: ${e.message}", Toast.LENGTH_LONG).show()
                },
            )
        }
    }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) { backupBusy = false; return@rememberLauncherForActivityResult }
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                DataBackup.importFrom(context, uri)
            }
            backupBusy = false
            when (result) {
                is DataBackup.ImportResult.NeedsRestart -> Toast.makeText(
                    context,
                    "Backup imported. Fully close and reopen NOOP for it to take effect.",
                    Toast.LENGTH_LONG,
                ).show()
                is DataBackup.ImportResult.Failed -> Toast.makeText(
                    context, result.message, Toast.LENGTH_LONG,
                ).show()
            }
        }
    }

    // Modern Photo Picker for the optional profile photo (no READ_EXTERNAL_STORAGE permission needed).
    // Returns a single image Uri (or null if cancelled); we decode + downscale + persist off the main
    // thread via ProfileAvatarStore, which updates the live avatar everywhere. Stored only on this phone.
    val avatarPickerLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val ok = withContext(Dispatchers.IO) {
                ProfileAvatarStore.setAvatarFromUri(context, uri)
            }
            if (!ok) {
                Toast.makeText(context, "Couldn't use that photo. Try another.", Toast.LENGTH_LONG).show()
            }
        }
    }

    ScreenScaffold(
        title = uiString(R.string.l10n_settings_screen_settings_c7f73bb5),
        subtitle = "Your numbers, your strap, and how NOOP works. All on this phone.",
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the static time-of-day sky settles
        // into the theme canvas behind the top of the list, exactly like the liquid Today. This is a long,
        // scroll-heavy list with NO hero gauge, so the liquid finish here is just the sky + liquidPress on
        // the tappable rows. Gated on the same day-cycle background pref Today reads, so turning that off
        // returns Settings to the plain dark canvas too.
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {
        // Read the revision counter so every profile write recomposes this subtree
        // (SharedPreferences is not observable; `mutate` bumps `rev` after each write).
        @Suppress("UNUSED_VARIABLE") val tick = rev

        // --- Profile photo (optional, on-device) ---
        // Split into its own section ahead of the body-numbers Profile card, mirroring the iOS
        // SettingsView `profilePhotoCard` (person.crop.circle, the offline blurb). A large avatar + a
        // Choose/Change button and, once set, a Remove. Local-only and honest: the picked image is
        // downscaled and kept on this phone, never uploaded. Reads ProfileAvatarStore.hasAvatar
        // (snapshot state) so the controls update the instant a photo is set or cleared.
        // Day streak (#569): consecutive days with a Charge score, computed on-device from your own
        // history. Uses NoopCard directly (not SettingsSection) to keep the wiring self-contained.
        val streaks by vm.streaks.collectAsStateWithLifecycle()
        NoopCard(tint = Palette.chargeColor) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(uiString(R.string.settings_streak_title), style = NoopType.subhead, color = Palette.textPrimary)
                Text(
                    pluralStringResource(R.plurals.settings_streak_run, streaks.current, streaks.current),
                    style = NoopType.subhead, color = Palette.chargeColor,
                )
                Text(
                    pluralStringResource(R.plurals.settings_streak_longest, streaks.longest, streaks.longest),
                    style = NoopType.footnote, color = Palette.textSecondary,
                )
            }
        }

        SettingsCard(
            icon = Icons.Outlined.AccountCircle,
            title = uiString(R.string.l10n_settings_screen_profile_photo_33f385bb),
            blurb = "Optional. Add a photo for the avatar in the top-left. Stored only on this phone. NOOP is offline, so it's never uploaded.",
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                ProfileAvatar(size = 64.dp, contentDescription = uiString(R.string.l10n_settings_screen_profile_photo_33f385bb))
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        NoopButton(
                            text = if (ProfileAvatarStore.hasAvatar) "Change photo" else "Choose photo",
                            kind = NoopButtonKind.Secondary,
                            modifier = Modifier.weight(1f),
                            onClick = {
                                avatarPickerLauncher.launch(
                                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                )
                            },
                        )
                        if (ProfileAvatarStore.hasAvatar) {
                            NoopButton(
                                text = uiString(R.string.l10n_settings_screen_remove_photo_c8f5eda8),
                                kind = NoopButtonKind.Tertiary,
                                modifier = Modifier.weight(1f),
                                onClick = { ProfileAvatarStore.clearAvatar(context) },
                            )
                        }
                    }
                }
            }
        }

        // --- Profile ---
        SettingsCard(
            icon = Icons.Outlined.Person,
            title = uiString(R.string.l10n_settings_screen_profile_ff4fc027),
            blurb = "These power your heart-rate zones, calorie estimates and recovery baselines. Keep them accurate.",
        ) {
            Column {
                SettingsFormRow(label = uiString(R.string.l10n_settings_screen_age_ff9f1ff3)) {
                    StepperField(
                        value = profile.age.toString(),
                        accessibility = "Age, ${profile.age} years",
                        // #146: age is derived from a stored date of birth, so it advances on its own. The
                        // stepper re-anchors the DOB via setAge (which clamps to 13..100 — age feeds the
                        // Fitness Age + Vitality engines that gate on age > 0, so it must never go 0/negative).
                        onMinus = { mutate { profile.setAge(profile.age - 1) } },
                        onPlus = { mutate { profile.setAge(profile.age + 1) } },
                    )
                }
                SettingsRowDivider()
                SettingsFormRow(label = uiString(R.string.l10n_settings_screen_sex_e301dd60)) {
                    SegmentedPillControl(
                        items = SEX_OPTIONS,
                        selection = SEX_OPTIONS.firstOrNull { it.tag == profile.sex } ?: SEX_OPTIONS[0],
                        label = { it.label },
                        onSelect = { mutate { profile.sex = it.tag } },
                    )
                }
                SettingsRowDivider()
                SettingsFormRow(label = uiString(R.string.l10n_settings_screen_weight_69c0b815)) {
                    // Imperial mode steps in whole pounds and stores the kg equivalent; metric steps in
                    // 0.5 kg. The profile is always SI — only the entry unit changes.
                    if (unitSystem == UnitSystem.IMPERIAL) {
                        val lb = UnitFormatter.kgToPounds(profile.weightKg)
                        StepperField(
                            value = "%.0f".format(lb),
                            unit = "lb",
                            accessibility = "Weight, ${lb.roundToInt()} pounds",
                            onMinus = { mutate { profile.weightKg = (lb - 1) / UnitFormatter.POUNDS_PER_KILOGRAM } },
                            onPlus = { mutate { profile.weightKg = (lb + 1) / UnitFormatter.POUNDS_PER_KILOGRAM } },
                        )
                    } else {
                        StepperField(
                            value = "%.1f".format(profile.weightKg),
                            unit = "kg",
                            accessibility = "Weight in kilograms",
                            onMinus = { mutate { profile.weightKg -= 0.5 } },
                            onPlus = { mutate { profile.weightKg += 0.5 } },
                        )
                    }
                }
                SettingsRowDivider()
                SettingsFormRow(label = uiString(R.string.l10n_settings_screen_height_3f608b49)) {
                    // Imperial mode steps in whole inches and stores the cm equivalent; metric steps in cm.
                    if (unitSystem == UnitSystem.IMPERIAL) {
                        val (ft, inch) = UnitFormatter.cmToFeetInches(profile.heightCm)
                        val totalInches = UnitFormatter.cmToInches(profile.heightCm).roundToInt()
                        StepperField(
                            value = "$ft′ $inch″",
                            accessibility = "Height, $ft feet $inch inches",
                            onMinus = { mutate { profile.heightCm = (totalInches - 1) * UnitFormatter.CENTIMETERS_PER_INCH } },
                            onPlus = { mutate { profile.heightCm = (totalInches + 1) * UnitFormatter.CENTIMETERS_PER_INCH } },
                        )
                    } else {
                        StepperField(
                            value = "%.0f".format(profile.heightCm),
                            unit = "cm",
                            accessibility = "Height in centimetres",
                            onMinus = { mutate { profile.heightCm -= 1 } },
                            onPlus = { mutate { profile.heightCm += 1 } },
                        )
                    }
                }
                SettingsRowDivider()
                // Waist (optional): the one extra body measure that unlocks the Fitness Age VO₂max
                // estimate. Unset (0) by design — the headline Fitness Age never needs it — so it shows
                // "Add" until entered, then steps like Height (inches in imperial, cm in metric).
                // First tap from unset seeds a typical adult waist rather than 1 cm.
                SettingsFormRow(label = uiString(R.string.l10n_settings_screen_waist_optional_d5356703)) {
                    Column(horizontalAlignment = Alignment.End) {
                        val hasWaist = profile.waistCm > 0.0
                        if (unitSystem == UnitSystem.IMPERIAL) {
                            val totalInches = UnitFormatter.cmToInches(profile.waistCm).roundToInt()
                            StepperField(
                                value = if (hasWaist) "%d″".format(totalInches) else "Add",
                                accessibility = if (hasWaist) {
                                    "Waist, $totalInches inches"
                                } else {
                                    "Waist, not set. Optional: adds your VO₂max estimate"
                                },
                                valueColor = if (hasWaist) Palette.textPrimary else Palette.textTertiary,
                                onMinus = { mutate { profile.waistCm = waistInchesStep(profile.waistCm, up = false) } },
                                onPlus = { mutate { profile.waistCm = waistInchesStep(profile.waistCm, up = true) } },
                            )
                        } else {
                            StepperField(
                                value = if (hasWaist) "%.0f".format(profile.waistCm) else "Add",
                                unit = if (hasWaist) "cm" else null,
                                accessibility = if (hasWaist) {
                                    "Waist in centimetres"
                                } else {
                                    "Waist, not set. Optional: adds your VO₂max estimate"
                                },
                                valueColor = if (hasWaist) Palette.textPrimary else Palette.textTertiary,
                                onMinus = { mutate { profile.waistCm = waistCmStep(profile.waistCm, up = false) } },
                                onPlus = { mutate { profile.waistCm = waistCmStep(profile.waistCm, up = true) } },
                            )
                        }
                        Spacer(Modifier.height(6.dp))
                        Text(
                            text = if (hasWaist) "Adds your VO₂max estimate" else "Optional · adds your VO₂max estimate",
                            style = NoopType.footnote,
                            color = if (hasWaist) Palette.accent else Palette.textTertiary,
                        )
                    }
                }
                SettingsRowDivider()
                SettingsFormRow(label = uiString(R.string.l10n_settings_screen_max_heart_rate_3d4ed858)) {
                    Column(horizontalAlignment = Alignment.End) {
                        StepperField(
                            value = if (profile.hrMaxOverride > 0) profile.hrMaxOverride.toString() else "Auto",
                            unit = "bpm",
                            accessibility = if (profile.hrMaxOverride == 0) {
                                "Max heart rate override, automatic"
                            } else {
                                "Max heart rate override, ${profile.hrMaxOverride} bpm"
                            },
                            valueColor = if (profile.hrMaxOverride > 0) Palette.textPrimary else Palette.textTertiary,
                            onMinus = { mutate { profile.hrMaxOverride -= 1 } },
                            onPlus = { mutate { profile.hrMaxOverride += 1 } },
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            text = if (profile.hrMaxOverride > 0) {
                                "Manual override"
                            } else {
                                "Auto · ${profile.hrMaxAuto} bpm (Tanaka)"
                            },
                            style = NoopType.footnote,
                            color = if (profile.hrMaxOverride > 0) Palette.accent else Palette.textTertiary,
                        )
                    }
                }
                SettingsRowDivider()
                // Step calibration (#139/#132): daily steps = @57 counter ticks ÷ this divisor.
                // 1.0 = raw pass-through until the true 5/MG tick rate is known. The divisor goes
                // up to 30 because a 5/MG motion counter can overcount by ~24×; the stepper uses a
                // variable increment (fine near 1.0, coarse up top) so high values stay reachable.
                SettingsFormRow(label = uiString(R.string.l10n_settings_screen_step_calibration_351c09bf)) {
                    StepperField(
                        value = "%.1f".format(profile.stepTicksPerStep),
                        accessibility = "Step calibration, %.1f counter ticks per step"
                            .format(profile.stepTicksPerStep),
                        onMinus = { mutate { profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up = false) } },
                        onPlus = { mutate { profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up = true) } },
                    )
                }
                Text(
                    uiString(R.string.l10n_settings_screen_counter_ticks_per_step_leave_at_3ce8c1d5),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
                SettingsRowDivider()
                // Tap-through to the WHOOP 4.0 steps-ESTIMATE calibration (a SEPARATE thing from the 5/MG
                // @57 counter divisor above): a 4.0 sends no step count, so NOOP estimates steps from
                // motion and calibrates that to the phone. Opens the explainer + fit + comparison + manual
                // override screen. Mirrors the macOS Profile "Steps estimate" row.
                val stepsSummary = when {
                    profile.stepsManualCoefficient > 0 -> "Manual"
                    profile.stepsCalibrationCoefficient > 0 ->
                        "Auto · ${StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)} confidence"
                    else -> "Not calibrated"
                }
                val stepsRowInteraction = remember { MutableInteractionSource() }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 44.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .liquidPress(stepsRowInteraction)
                        .clickable(
                            interactionSource = stepsRowInteraction,
                            indication = null,
                        ) { showStepsCalibration = true }
                        .semantics {
                            contentDescription =
                                uiString(R.string.l10n_settings_screen_steps_estimate_calibration_stepssummary_opens_the_d6fbf995, stepsSummary)
                        }
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(uiString(R.string.l10n_settings_screen_steps_estimate_ce7a604d), style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                    Text(
                        stepsSummary,
                        style = NoopType.footnote,
                        color = if (profile.stepsManualCoefficient > 0) Palette.accent else Palette.textTertiary,
                    )
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Text(
                    uiString(R.string.l10n_settings_screen_for_a_whoop_4_0_which_df865854),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }

        // --- Units ---
        // Imperial/Metric display toggle + a separate temperature override. Display-only — nothing
        // stored changes; NOOP keeps everything in SI and converts at the point of display. Mirrors the
        // macOS Settings → Units card.
        SettingsCard(
            icon = Icons.Filled.Straighten,
            title = uiString(R.string.l10n_settings_screen_units_12748281),
            blurb = "Choose how distances, weights, heights, temperatures and Effort are shown. Your data is always stored the same way. This only changes the display.",
        ) {
            Column {
                SettingsFormRow(label = uiString(R.string.l10n_settings_screen_measurement_system_701d765d)) {
                    SegmentedPillControl(
                        items = listOf(UnitSystem.METRIC, UnitSystem.IMPERIAL),
                        selection = unitSystem,
                        label = { if (it == UnitSystem.METRIC) "Metric" else "Imperial" },
                        onSelect = {
                            unitSystem = it
                            NoopPrefs.setUnitSystem(context, it)
                        },
                    )
                }
                SettingsRowDivider()
                SettingsFormRow(label = uiString(R.string.l10n_settings_screen_temperature_0a9062a9)) {
                    // Three-way: "Match" follows the system above; °C / °F pin it explicitly. Stored as an
                    // empty string ("match") or the TemperatureUnit raw value.
                    SegmentedPillControl(
                        items = listOf("", TemperatureUnit.CELSIUS.raw, TemperatureUnit.FAHRENHEIT.raw),
                        selection = temperatureRaw,
                        label = {
                            when (it) {
                                TemperatureUnit.CELSIUS.raw -> "°C"
                                TemperatureUnit.FAHRENHEIT.raw -> "°F"
                                else -> "Match"
                            }
                        },
                        onSelect = {
                            temperatureRaw = it
                            NoopPrefs.setTemperatureUnit(context, TemperatureUnit.fromRaw(it))
                        },
                    )
                }
                SettingsRowDivider()
                // Effort scale (#268) — NOOP's native 0–100 Effort or WHOOP's 0–21 Day Strain axis.
                // Display-only; the stored value never changes, so a flip just re-labels every read-out.
                SettingsFormRow(label = uiString(R.string.l10n_settings_screen_effort_scale_81afa9ef)) {
                    SegmentedPillControl(
                        items = listOf(EffortScale.HUNDRED, EffortScale.WHOOP),
                        selection = effortScale,
                        label = { if (it == EffortScale.HUNDRED) "0-100" else "0-21" },
                        onSelect = {
                            effortScale = it
                            UnitPrefs.setEffortScale(context, it)
                        },
                    )
                }
            }
        }

        // --- Appearance (Theme) ---
        SettingsCard(
            icon = Icons.Filled.Brightness6,
            title = uiString(R.string.l10n_settings_screen_appearance_41def7a0),
            blurb = "Choose Light, Dark, or follow your system. Dark is the signature near-black; Light keeps the same clean look on a bright canvas.",
        ) {
            SettingsFormRow(label = uiString(R.string.l10n_settings_screen_theme_a797e309)) {
                SegmentedPillControl(
                    items = listOf(AppearanceMode.SYSTEM, AppearanceMode.LIGHT, AppearanceMode.DARK),
                    selection = themeMode,
                    label = { it.label },
                    onSelect = { mode ->
                        themeMode = mode
                        AppearancePrefs.set(context, mode)
                    },
                )
            }
            SettingsRowDivider()   // #79 parity: the hairline every other section has between FormRows (Android rows
                           // were already 16dp-spaced, unlike iOS where they touched — this matches both)
            SettingsFormRow(label = uiString(R.string.l10n_settings_screen_chart_colours_525f4a37)) {
                // Titanium = brand gold/amber/blue ramps; Classic = throwback red→green readiness scale
                // (cool→hot zones, green→red stress). Re-colours every gauge/chart, in both schemes.
                SegmentedPillControl(
                    items = listOf(ChartStyle.TITANIUM, ChartStyle.CLASSIC),
                    selection = chartStyle,
                    label = { it.label },
                    onSelect = { style ->
                        chartStyle = style
                        ChartStylePrefs.set(context, style)
                    },
                )
            }
            SettingsRowDivider()
            // Chrome accent colour — links/buttons/selection tint only. The recovery/strain/sleep DATA
            // colours follow "Chart colours", never this. Custom reveals RGB sliders.
            SettingsFormRow(label = uiString(R.string.l10n_settings_screen_accent)) {
                SegmentedPillControl(
                    items = listOf(AccentColor.MINT, AccentColor.WHOOP_BLUE, AccentColor.CUSTOM),
                    selection = accentColor,
                    label = { it.label },
                    onSelect = { c ->
                        accentColor = c
                        AccentPrefs.setColor(context, c)
                    },
                )
            }
            if (accentColor == AccentColor.CUSTOM) {
                SettingsRowDivider()
                AccentCustomPicker(
                    hex = accentCustomHex,
                    onHexChange = { hex ->
                        accentCustomHex = hex
                        AccentPrefs.setCustomHex(context, hex)
                    },
                )
            }
            SettingsRowDivider()
            // Trend chart style (line vs bar). Display-only: flips the Trends tab's charts between the
            // gradient line and value-ramp bars. The plotted data is identical either way.
            SettingsFormRow(label = uiString(R.string.l10n_settings_screen_trend_charts_19085c81)) {
                SegmentedPillControl(
                    items = listOf(TrendChartStyle.LINE, TrendChartStyle.BAR),
                    selection = trendChartStyle,
                    label = { if (it == TrendChartStyle.BAR) "Bars" else "Line" },
                    onSelect = { style ->
                        trendChartStyle = style
                        UnitPrefs.setTrendChartStyle(context, style)
                    },
                )
            }
            SettingsRowDivider()
            // Sleep chart style (#sleep-chart-style). Display-only: "Classic" keeps the per-stage-rows
            // timeline; "Filled" swaps the Sleep tab's stage chart for a single stepped hypnogram with the
            // stages stacked by depth and each column filled to the baseline. Same data either way; this only
            // changes the drawing, and it falls back to Classic on a night with no timestamped segments.
            SettingsFormRow(label = "Sleep chart") {
                SegmentedPillControl(
                    items = listOf(SleepChartStyle.CLASSIC, SleepChartStyle.FILLED, SleepChartStyle.RIBBON),
                    selection = sleepChartStyle,
                    label = {
                        when (it) {
                            SleepChartStyle.FILLED -> "Filled"
                            SleepChartStyle.RIBBON -> "Ribbon"
                            else -> "Classic"
                        }
                    },
                    onSelect = { style ->
                        sleepChartStyle = style
                        UnitPrefs.setSleepChartStyle(context, style)
                    },
                    // Three segments — share the row width equally so the labels can't widen the card past
                    // the screen (the component's own guidance for longer option sets).
                    adaptsToAvailableWidth = true,
                )
            }
            // In-app "Reduce motion in NOOP" (#941) — parity with the Apple quiet-motion toggle. Poses every
            // looping surface still via the third rememberPoseStill() signal. (SettingsRowDivider, not the
            // file-private RowDivider used elsewhere, which isn't visible here.)
            SettingsRowDivider()
            SettingsToggleRow(
                title = uiString(R.string.l10n_settings_screen_reduce_motion_in_noop_59a6180d),
                detail = uiString(R.string.l10n_settings_screen_holds_the_liquid_gauges_the_sky_41872b57),
                checked = quietMotion,
                onCheckedChange = {
                    quietMotion = it
                    NoopPrefs.setQuietMotion(context, it)
                },
            )

            // Day-cycle background (#698): the time-of-day scene behind Today. On by default. Off swaps it
            // for a plain dark canvas for people who find the moving scene distracting. Takes effect next
            // time Today is opened (the pref is read once on entry, like the other Today-screen toggles).
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        uiString(R.string.l10n_settings_screen_day_cycle_background_8c254f01),
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                    )
                    Text(
                        uiString(R.string.l10n_settings_screen_shows_a_soft_sunrise_day_dusk_2d20b417),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Switch(
                    checked = showDayCycleBackground,
                    onCheckedChange = {
                        showDayCycleBackground = it
                        NoopPrefs.setShowDayCycleBackground(context, it)
                    },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Palette.surfaceBase,
                        checkedTrackColor = Palette.accent,
                        uncheckedThumbColor = Palette.textSecondary,
                        uncheckedTrackColor = Palette.surfaceInset,
                        uncheckedBorderColor = Palette.hairline,
                    ),
                )
            }

            // Sky behind cards (opt-in): extend the day-cycle sky behind the WHOLE Today scroll so the Card
            // transparency slider reveals it under every card, not just the hero. Off = the sky stays a top
            // band and lower cards fade toward the flat canvas. Needs the day-cycle background to be on.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        uiString(R.string.l10n_settings_screen_sky_behind_cards_efbe5cb8),
                        style = NoopType.subhead,
                        color = if (showDayCycleBackground) Palette.textPrimary else Palette.textTertiary,
                    )
                    Text(
                        uiString(R.string.l10n_settings_screen_extends_the_sky_behind_the_whole_39bb82cc),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Switch(
                    enabled = showDayCycleBackground,
                    checked = skyBehindCards && showDayCycleBackground,
                    onCheckedChange = {
                        skyBehindCards = it
                        NoopPrefs.setSkyBehindCards(context, it)
                    },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Palette.surfaceBase,
                        checkedTrackColor = Palette.accent,
                        uncheckedThumbColor = Palette.textSecondary,
                        uncheckedTrackColor = Palette.surfaceInset,
                        uncheckedBorderColor = Palette.hairline,
                    ),
                )
            }

            // Card transparency: scale every frosted card's glass toward the background. Live-preview (the
            // cards on THIS screen update as you drag) via CardAppearance; saved on release. Default solid.
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        uiString(R.string.l10n_settings_screen_card_transparency_c5c7b4f3),
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        uiString(R.string.l10n_settings_screen_1f_cardopacity_100_toint_51f10397, ((1f - cardOpacity) * 100).toInt()),
                        style = NoopType.number(15f),
                        color = Palette.accent,
                    )
                }
                Text(
                    uiString(R.string.l10n_settings_screen_how_see_through_the_cards_heart_436105b9),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
                Slider(
                    // The slider shows TRANSPARENCY (0 = solid, 1 = fully clear); we store the OPACITY.
                    value = 1f - cardOpacity,
                    onValueChange = { t ->
                        cardOpacity = 1f - t
                        CardAppearance.opacity = cardOpacity   // live preview on every card on-screen
                    },
                    onValueChangeFinished = {
                        NoopPrefs.setCardOpacityPercent(context, (cardOpacity * 100).toInt())
                    },
                    valueRange = 0f..1f,
                    colors = SliderDefaults.colors(
                        thumbColor = Palette.accent,
                        activeTrackColor = Palette.accent,
                        inactiveTrackColor = Palette.surfaceInset,
                    ),
                )
            }
        }

        // --- App icon (v3 "Titanium & Gold") ---
        // Two staged launcher icons — machined titanium (default) and blued/dark-blue titanium. The
        // swap is done by enabling exactly one <activity-alias> (.IconDefault / .IconNavy) at runtime;
        // the launcher may take a beat (or briefly disappear/redraw) while it re-reads the icon.
        SettingsCard(
            icon = Icons.Filled.Palette,
            title = uiString(R.string.l10n_settings_screen_app_icon_abde7a74),
            blurb = "Choose how NOOP looks on your home screen. The launcher may take a moment to refresh the icon after you change it.",
        ) {
            SettingsFormRow(label = uiString(R.string.l10n_settings_screen_icon_716f63b9)) {
                SegmentedPillControl(
                    items = listOf(false, true),
                    selection = appIconNavy,
                    label = { if (it) "Blue Titanium" else "Titanium" },
                    onSelect = { navy ->
                        appIconNavy = navy
                        setAppIcon(context, navy)
                    },
                )
            }
        }

        // --- Strap ---
        SettingsCard(
            icon = Icons.Filled.Sensors,
            title = uiString(R.string.l10n_settings_screen_strap_02b88eeb),
            blurb = "NOOP pairs directly with your WHOOP over Bluetooth: no WHOOP app, no cloud.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    StatePill(
                        title = strapStatusTitle(live.bonded, live.connected),
                        tone = strapTone(live.bonded, live.connected),
                        pulsing = live.connected,
                    )
                    live.batteryPct?.let { pct ->
                        StatePill(
                            title = uiString(R.string.l10n_settings_screen_battery_pct_roundtoint_e02e2891, pct.roundToInt()) +
                                if (live.charging == true) " · Charging" else "",
                            tone = batteryTone(pct),
                            showsDot = false,
                        )
                    }
                }
                Text(
                    strapStatusDetail(live.bonded, live.connected, live.scanning),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    NoopButton(
                        text = if (live.scanning) "Searching…" else "Re-scan",
                        leadingIcon = Icons.Filled.Refresh,
                        kind = NoopButtonKind.Primary,
                        enabled = !live.scanning,
                        onClick = { requestScan() },
                    )

                    NoopButton(
                        text = uiString(R.string.l10n_settings_screen_disconnect_ed28e068),
                        leadingIcon = Icons.Filled.Cancel,
                        kind = NoopButtonKind.Secondary,
                        enabled = live.connected || live.bonded,
                        onClick = { vm.disconnect() },
                    )
                }

                // Rename the strap's BLE advertising name (WHOOP 4.0 only). Writes the name to the strap
                // firmware (cmd 77); it reboots to apply, so the new name shows on the next connect. Handy
                // for a second-hand band stuck on the previous owner's name. Reversible.
                if (live.connected && !live.whoop5Detected) {
                    var nameDraft by remember(live.advertisingName) { mutableStateOf(live.advertisingName ?: "") }
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(uiString(R.string.l10n_settings_screen_strap_name_350de547), style = NoopType.subhead, color = Palette.textPrimary)
                        Text(
                            uiString(R.string.l10n_settings_screen_rename_your_strap_s_bluetooth_name_6032668b) +
                                "reboots to apply, then reconnects with the new name.",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                        OutlinedTextField(
                            value = nameDraft,
                            onValueChange = { nameDraft = it.take(24) },
                            singleLine = true,
                            placeholder = { Text(uiString(R.string.l10n_settings_screen_whoop_a3650379), style = NoopType.body, color = Palette.textTertiary) },
                            modifier = Modifier.fillMaxWidth(),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedTextColor = Palette.textPrimary,
                                unfocusedTextColor = Palette.textPrimary,
                                focusedBorderColor = Palette.accent,
                                unfocusedBorderColor = Palette.hairline,
                                cursorColor = Palette.accent,
                                focusedContainerColor = Palette.surfaceInset,
                                unfocusedContainerColor = Palette.surfaceInset,
                            ),
                        )
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            NoopButton(
                                text = uiString(R.string.l10n_settings_screen_rename_d3f4cb89),
                                leadingIcon = Icons.Filled.Edit,
                                kind = NoopButtonKind.Primary,
                                enabled = live.bonded && nameDraft.isNotBlank(),
                                onClick = { vm.ble.renameStrap(nameDraft) },
                            )
                            live.renameStatus?.let {
                                Text(it, style = NoopType.footnote, color = Palette.textSecondary, modifier = Modifier.weight(1f))
                            }
                        }
                    }
                }

                // Keep streaming when the app is closed (Android foreground service). On Mac, NOOP
                // already keeps your strap connected from the menu bar — just close the window.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            uiString(R.string.l10n_settings_screen_keep_connected_in_the_background_44499d45),
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            uiString(R.string.l10n_settings_screen_keeps_streaming_from_your_strap_with_d31b4af9),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = backgroundConnection,
                        onCheckedChange = {
                            backgroundConnection = it
                            vm.setBackgroundConnection(it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                    )
                }

                // "Faster history sync" (#533, EXPERIMENTAL): asks Android for a shorter GATT connection
                // interval for the BOUNDED historical-offload burst only. Off by default — BLE behaviour
                // can't be CI-tested, so this needs real-strap field reports on both the speedup and the
                // battery cost. The live/overnight stream deliberately never escalates.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            stringResource(R.string.fast_history_sync),
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(R.string.fast_history_sync_desc),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = fastHistorySync,
                        onCheckedChange = {
                            fastHistorySync = it
                            vm.setFastHistorySync(it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                    )
                }

                // "Faster Bluetooth link" (#533, EXPERIMENTAL): the other, orthogonal sync-speed lever —
                // prefer the LE 2M PHY around the offload. Same bytes in half the airtime, so unlike the
                // interval lever above it should cost LESS strap radio energy, not more. Separate toggle so
                // a field report can attribute which lever did what. Off by default: the strap may decline
                // it, 2M trades range for speed, and BLE behaviour can't be CI-tested. The negotiated PHY
                // lands in the strap log (onPhyUpdate).
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            stringResource(R.string.fast_link_phy),
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(R.string.fast_link_phy_desc),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = fastLinkPhy,
                        onCheckedChange = {
                            fastLinkPhy = it
                            vm.setFastLinkPhy(it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                    )
                }

                // "Keep NOOP alive overnight" (#386): the battery-optimisation whitelist. Shown ONLY while
                // background connection is on (meaningless otherwise), so it never adds noise on a
                // foreground-only setup. `checked` reflects the LIVE system exempt state, so an already-exempt
                // phone shows it on and is never prompted again. POPUP DISCIPLINE: turning it ON fires exactly
                // ONE system dialog; the OEM auto-start screen (aggressive vendors only) is a SEPARATE
                // text-link, never chained onto that dialog, so one tap can't spawn two popups. The whitelist
                // adds no battery cost of its own — it stops a premature kill; the real cost is the two
                // toggles below.
                if (backgroundConnection) {
                    // Re-read the LIVE exempt state on every ON_RESUME so the toggle flips to on the moment
                    // the user returns from the system whitelist dialog. Reading it plainly in composition
                    // wouldn't recompose on resume — it'd show a stale "off", look like it failed, and invite
                    // a SECOND (duplicate) popup, defeating the popup discipline.
                    val lifecycleOwner = LocalLifecycleOwner.current
                    var batteryExempt by remember {
                        mutableStateOf(com.noop.ble.BackgroundHealth.isBatteryExempt(context))
                    }
                    DisposableEffect(lifecycleOwner) {
                        val obs = LifecycleEventObserver { _, event ->
                            if (event == Lifecycle.Event.ON_RESUME) {
                                batteryExempt = com.noop.ble.BackgroundHealth.isBatteryExempt(context)
                            }
                        }
                        lifecycleOwner.lifecycle.addObserver(obs)
                        onDispose { lifecycleOwner.lifecycle.removeObserver(obs) }
                    }
                    val oemAutostart = remember { com.noop.ble.BackgroundHealth.oemAutostartIntent(context) }
                    // Only NAME the manufacturer as a killer when it actually is one — a Pixel/Samsung
                    // shouldn't read "especially Google". The whitelist still helps everyone (it also
                    // exempts from Doze deferral), so the row still shows; only the copy is vendor-aware.
                    val aggressiveVendor = remember { com.noop.ble.BackgroundHealth.isAggressiveVendor() }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                uiString(R.string.l10n_settings_screen_keep_noop_alive_overnight_e43b2fba),
                                style = NoopType.subhead,
                                color = Palette.textPrimary,
                            )
                            // #386: these were hardcoded literals — and INVISIBLE to the i18n gate, whose
                            // Android regex only matches a literal directly after `Text(`. Inside a
                            // `Text(if ...)` expression it slid past, so this whole warning shipped
                            // English-only to de/es/fr while the audit reported clean. Now resources.
                            // TWO "needed" strings rather than one with a %s subject fragment: verb
                            // agreement differs once translated — German needs "Ihr Telefon … kann" but
                            // "Manche Telefone … können", so a composed subject would be ungrammatical.
                            Text(
                                if (batteryExempt) {
                                    uiString(R.string.keep_alive_allowed)
                                } else if (aggressiveVendor) {
                                    uiString(R.string.keep_alive_needed_vendor, android.os.Build.MANUFACTURER)
                                } else {
                                    uiString(R.string.keep_alive_needed_generic)
                                },
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                            // Aggressive-OEM only, and only while not yet exempt: a SEPARATE, explicit link to
                            // the vendor's auto-start screen (which the generic whitelist can't reach). One
                            // extra tap by choice — never auto-opened alongside the whitelist dialog.
                            if (!batteryExempt && oemAutostart != null) {
                                Text(
                                    uiString(R.string.l10n_settings_screen_some_phones_also_need_auto_start_79b7147b),
                                    style = NoopType.footnote,
                                    color = Palette.accent,
                                    modifier = Modifier
                                        .padding(top = 6.dp)
                                        .clickable { runCatching { context.startActivity(oemAutostart) } },
                                )
                            }
                        }
                        Switch(
                            checked = batteryExempt,
                            // A system grant can't be toggled OFF from here (that's a system action): a tap
                            // only ever REQUESTS it, and when already exempt the switch is inert (no re-prompt).
                            onCheckedChange = { wantOn ->
                                if (wantOn && !batteryExempt) {
                                    // The whole feature exists for ROMs that strip things — so the fallback
                                    // is guarded too: if BOTH the exemption dialog and the app-settings page
                                    // are missing, no-op rather than crash (the OEM link below is another path).
                                    runCatching {
                                        context.startActivity(com.noop.ble.BackgroundHealth.batteryExemptionIntent(context))
                                    }.onFailure {
                                        runCatching {
                                            context.startActivity(com.noop.ble.BackgroundHealth.appBatterySettingsIntent(context))
                                        }
                                    }
                                }
                            },
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Palette.surfaceBase,
                                checkedTrackColor = Palette.accent,
                                uncheckedThumbColor = Palette.textSecondary,
                                uncheckedTrackColor = Palette.surfaceInset,
                                uncheckedBorderColor = Palette.hairline,
                            ),
                        )
                    }
                }

                // Continuous HRV capture: keep the dense beat-to-beat (R-R) stream armed even with no Live
                // screen open, so the strap banks far more data overnight for better HRV/recovery/sleep.
                // Honest battery framing — continuous HR streaming uses more battery. Needs background
                // connection on (there's no background link to stream over otherwise). Default OFF.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            uiString(R.string.l10n_settings_screen_continuous_hrv_capture_1f0805d8),
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            uiString(R.string.l10n_settings_screen_keeps_the_detailed_beat_to_beat_87b78edd),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = continuousHrv,
                        onCheckedChange = {
                            continuousHrv = it
                            vm.setContinuousHrv(it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                    )
                }

                // Overnight only (#927): window-gate the continuous stream to the nightly quiet-hours
                // window. Shown only while Continuous HRV capture is on; default OFF so existing users
                // keep the always-on behaviour with no migration.
                if (continuousHrv) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                uiString(R.string.l10n_settings_screen_overnight_only_05747985),
                                style = NoopType.subhead,
                                color = Palette.textPrimary,
                            )
                            Text(
                                uiString(R.string.l10n_settings_screen_runs_the_continuous_hrv_stream_only_3fed47c5) +
                                "Note: continuous background HRV capture (including daytime naps) is paused outside this window. " +
                                "For on-demand daytime HRV readings (including naps), use the \"Take an HRV reading\" button on the Live screen.",
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                        }
                        Switch(
                            checked = continuousHrvOvernight,
                            onCheckedChange = {
                                continuousHrvOvernight = it
                                vm.setContinuousHrvOvernight(it)
                            },
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Palette.surfaceBase,
                                checkedTrackColor = Palette.accent,
                                uncheckedThumbColor = Palette.textSecondary,
                                uncheckedTrackColor = Palette.surfaceInset,
                                uncheckedBorderColor = Palette.hairline,
                            ),
                        )
                    }
                }

                // HRV window (#141) — grouped with the other HRV settings (#155). Measure nightly HRV over
                // the whole night (NOOP's long-standing value) or DEEP sleep only (WHOOP-style, reads lower
                // and more comparable to WHOOP/Polar). Unlike the Effort scale this CHANGES the number, so a
                // switch forces a re-score + re-baseline.
                SettingsFormRow(label = uiString(R.string.l10n_settings_screen_hrv_window_e74320b8)) {
                    SegmentedPillControl(
                        items = listOf(HrvWindow.WHOLE_NIGHT, HrvWindow.DEEP_SLEEP),
                        selection = hrvWindow,
                        // #153: "Night" (not "Whole night") so the two-segment pill reads the same as the iOS
                        // picker and stays short — keeps the label consistent across platforms.
                        label = { if (it == HrvWindow.DEEP_SLEEP) "Deep sleep" else "Night" },
                        onSelect = {
                            hrvWindow = it
                            UnitPrefs.setHrvWindow(context, it)
                            // #201: the new window shifts every night's avgHrv, so the HRV baseline must reflect
                            // it too — but a plain re-score already achieves that. analyzeRecent re-scores the
                            // recent ~21 nights' avgHrv under the new window AND re-folds the HRV baseline from
                            // them in the same pass, and the baseline's 14-night-half-life EWMA is dominated by
                            // that fresh re-scored tail. So DON'T re-anchor the baseline epoch: doing so would
                            // drop all history and force a multi-night "calibrating" reset for someone who already
                            // has plenty of nights (that reset reading as "the setting is broken" was #195). Clear
                            // the analyze watermark so the re-score runs even though the raw HR fingerprint is
                            // unchanged. A genuine cold-start user (<4 valid nights) still calibrates honestly.
                            NoopPrefs.setAnalyzeWatermark(context, "")
                            vm.syncNow()
                            Toast.makeText(
                                context,
                                "Re-scoring your recent nights over the ${if (it == HrvWindow.DEEP_SLEEP) "deep-sleep" else "whole-night"} window. Charge updates as soon as it's done.",
                                Toast.LENGTH_LONG,
                            ).show()
                        },
                    )
                }
                Text(
                    uiString(R.string.l10n_settings_screen_whole_night_is_noop_s_default_fbfff434),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )

                // Diagnostics: export the strap connection log so people can attach it to a bug report.
                NoopButton(
                    text = uiString(R.string.l10n_settings_screen_share_strap_log_for_bug_reports_b9802500),
                    leadingIcon = Icons.Filled.Upload,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = !strapLogBusy,
                    onClick = {
                        strapLogBusy = true
                        scope.launch {
                            // try/finally: the flag must clear on any exit, not just the happy path (#961 follow-up).
                            try {
                                LogExport.shareStrapLog(context, vm.ble.exportLogText())
                            } finally {
                                strapLogBusy = false
                            }
                        }
                    },
                )
                if (strapLogBusy) {
                    NoopBusyRow()
                }

                // "WHOOP 4.0 vs 5.0/MG — what each can read and why" (FI-2 / #490). Shown to BOTH model
                // owners, so a 4.0 user understands their strap is fully supported (and why the firmware
                // broadcast-out is 5/MG-only while NOOP's own re-broadcast in Data Sources works on a 4.0).
                val modelComparisonInteraction = remember { MutableInteractionSource() }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .liquidPress(modelComparisonInteraction)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.surfaceInset)
                        .border(1.dp, Palette.hairline, RoundedCornerShape(10.dp))
                        .clickable(
                            interactionSource = modelComparisonInteraction,
                            indication = null,
                        ) { showModelComparison = true }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                        .semantics { contentDescription = uiString(R.string.l10n_settings_screen_whoop_4_0_versus_5_0_a54c5504) },
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            Icons.Filled.Info,
                            contentDescription = null,
                            tint = Palette.accent,
                            modifier = Modifier.size(18.dp),
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text(uiString(R.string.l10n_settings_screen_whoop_4_0_vs_5_0_2babb05a), style = NoopType.headline, color = Palette.textPrimary)
                            Text(
                                uiString(R.string.l10n_settings_screen_what_each_strap_can_read_and_51e7d3fc),
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                        Text("›", style = NoopType.title2, color = Palette.accent)
                    }
                }
            }
        }

        // #477 Power saving. Two BENIGN battery levers only: the offload-cadence stretch (%-gated) and
        // the HRV-capture pause (Battery-Saver-gated). The riskier connection-priority idle throttle is
        // deliberately not surfaced here — it stays dormant pending on-strap validation (#478).
        SettingsCard(
            icon = Icons.Filled.BatteryStd,
            title = stringResource(R.string.power_saving),
            blurb = stringResource(R.string.power_saving_blurb),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.power_saving_mode), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        stringResource(R.string.power_saving_mode_desc),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Switch(
                    checked = powerSaving,
                    onCheckedChange = {
                        powerSaving = it
                        vm.setPowerSaving(it)
                    },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Palette.surfaceBase,
                        checkedTrackColor = Palette.accent,
                        uncheckedThumbColor = Palette.textSecondary,
                        uncheckedTrackColor = Palette.surfaceInset,
                        uncheckedBorderColor = Palette.hairline,
                    ),
                )
            }
            if (powerSaving) {
                SettingsRowDivider()
                Column(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(stringResource(R.string.power_saving_kick_in), style = NoopType.subhead, color = Palette.textPrimary)
                        Text(stringResource(R.string.power_saving_pct, powerSavingBatteryPct), style = NoopType.subhead, color = Palette.accent)
                    }
                    Slider(
                        value = powerSavingBatteryPct.toFloat(),
                        // 10–30% snapping to 5% steps (10/15/20/25/30). steps = the 3 stops BETWEEN ends.
                        onValueChange = { powerSavingBatteryPct = it.roundToInt() },
                        onValueChangeFinished = { vm.setPowerSavingBatteryPct(powerSavingBatteryPct) },
                        valueRange = 10f..30f,
                        steps = 3,
                        colors = SliderDefaults.colors(
                            thumbColor = Palette.accent,
                            activeTrackColor = Palette.accent,
                            inactiveTrackColor = Palette.surfaceInset,
                        ),
                    )
                }
                SettingsRowDivider()
                // HRV pause: a sub-option of power saving, ON by default when the master is on.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(stringResource(R.string.power_saving_hrv_pause), style = NoopType.subhead, color = Palette.textPrimary)
                        Text(
                            stringResource(R.string.power_saving_hrv_pause_desc),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = pauseHrvOnPowerSave,
                        onCheckedChange = {
                            pauseHrvOnPowerSave = it
                            vm.setPauseHrvOnPowerSave(it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                    )
                }
            }
        }

        // Lower-frequency sections collapse behind a single default-closed disclosure (S3) so the
        // screen opens at the everyday handful instead of the full wall of cards. Nothing is removed;
        // the experimental probes, diagnostics, raw-capture export and Trends report all stay one tap
        // away. Mirrors the iOS SettingsView "Advanced" disclosure and the Test Centre Advanced group.
        SettingsDisclosureGroup(
            title = uiString(R.string.l10n_settings_screen_advanced_4d064726),
            subtitle = "Experimental probes, diagnostics, raw-sensor export, and the Trends report. Tucked away to keep the everyday screen tidy.",
            expanded = advancedOpen,
            onToggle = { advancedOpen = !advancedOpen; SettingsDisclosurePrefs.write(NoopPrefs.of(context), advancedOpen) },
        ) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.screenRowSpacing)) {
        // --- Experimental · WHOOP 5 / MG --- (hidden when the user is confidently on a 4.0, #22)
        if (showFiveMGControls) {
        SettingsCard(
            icon = Icons.Filled.Science,
            title = uiString(R.string.l10n_settings_screen_experimental_whoop_5_mg_41ef7041),
            blurb = "Live heart rate already works on a WHOOP 5/MG strap. These probes go further and try to coax more out of it. They are guesses, off by default, and only ever touch a 5/MG strap. WHOOP 4.0 is never affected.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        uiString(R.string.l10n_settings_screen_try_whoop_5_mg_protocol_probes_1d584653),
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = puffinExperiments,
                        onCheckedChange = {
                            puffinExperiments = it
                            puffinExperiment.isEnabled = it
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = uiString(R.string.l10n_settings_screen_try_whoop_5_mg_protocol_probes_1d584653)
                        },
                    )
                }
                Text(
                    uiString(R.string.l10n_settings_screen_on_a_5_mg_connection_noop_4557c8f8),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )

                // --- Broadcast heart rate (turn the strap into a standard BLE HR sensor). (#181) ---
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        uiString(R.string.l10n_settings_screen_broadcast_strap_hr_garmin_ant_a39d0654),
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = broadcastHr,
                        onCheckedChange = {
                            broadcastHr = it
                            puffinExperiment.broadcastHr = it
                            vm.ble.setBroadcastHr(it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = uiString(R.string.l10n_settings_screen_broadcast_heart_rate_d1af1c79)
                        },
                    )
                }
                Text(
                    uiString(R.string.l10n_settings_screen_makes_your_whoop_5_0_mg_b26b94c7),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )

                // --- ECG raw-data gate — an opt-in device-config WRITE with a mandatory read-back. (#891) ---
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        uiString(R.string.l10n_settings_screen_ecg_raw_data_gate_whoop_mg_only),
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = ecgRawData,
                        onCheckedChange = {
                            ecgRawData = it
                            puffinExperiment.ecgRawData = it
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription =
                                uiString(R.string.l10n_settings_screen_ecg_raw_data_gate_whoop_mg_only)
                        },
                    )
                }
                Text(
                    uiString(R.string.l10n_settings_screen_ecg_gate_blurb),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
                if (ecgRawData) {
                    Text(
                        uiString(R.string.l10n_settings_screen_ecg_gate_persistent_warning),
                        style = NoopType.caption,
                        color = Palette.statusWarning,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        NoopButton(
                            text = uiString(R.string.l10n_settings_screen_ecg_gate_turn_on),
                            kind = NoopButtonKind.Primary,
                            enabled = live.bonded && ecgVariantIsMG,
                            onClick = { vm.ble.setEcgRawDataGate(true) },
                        )
                        NoopButton(
                            text = uiString(R.string.l10n_settings_screen_ecg_gate_turn_off),
                            kind = NoopButtonKind.Secondary,
                            enabled = live.bonded && ecgVariantIsMG,
                            onClick = { vm.ble.setEcgRawDataGate(false) },
                        )
                    }
                    ecgGateReport?.let { report ->
                        Text(
                            report.summary,
                            style = NoopType.caption,
                            color = if (report.verdict == EcgRawDataGateReport.Verdict.CONFIRMED) {
                                Palette.statusPositive
                            } else {
                                Palette.textSecondary
                            },
                        )
                    }
                }

                // --- R22 deep-data unlock — the one probe that writes to the strap. (#174) ---
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        uiString(R.string.l10n_settings_screen_unlock_whoop_5_mg_deep_data_2f2bd226),
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = deepData,
                        onCheckedChange = {
                            deepData = it
                            puffinExperiment.isDeepDataEnabled = it
                            // #174: turning the switch OFF used to write nothing — it only hid the enable
                            // button, so the strap kept every flag the sequence set while the UI implied it
                            // had been undone. Now it offers the real undo. Turning it ON still writes
                            // nothing until the button is tapped.
                            if (!it) confirmingDeepDataDisable = true
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = uiString(R.string.l10n_settings_screen_unlock_whoop_5_mg_deep_data_70036ca8)
                        },
                    )
                }
                Text(
                    uiString(R.string.l10n_settings_screen_whoop_5_mg_straps_hand_a_b8b239e6),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
                if (deepData) {
                    NoopButton(
                        text = uiString(R.string.l10n_settings_screen_send_enable_sequence_to_strap_04ff8a22),
                        leadingIcon = Icons.Filled.Bolt,
                        kind = NoopButtonKind.Primary,
                        enabled = live.encryptedBond && live.worn,
                        onClick = { vm.ble.enableWhoop5DeepData() },
                    )
                    Text(
                        if (!live.encryptedBond) "Needs the full encrypted bond: close the official WHOOP app and pair the strap to NOOP first (a live-HR-only link can't carry the unlock)."
                        else if (!live.worn) "Put the strap on first. The deep stream is on-wrist only."
                        else "Wear the strap, tap once, then let it sync and share your strap log.",
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )
                    // #174: the undo. Offered whenever the flags may be set — which is any time the
                    // opt-in has been on, not only right after a send, because the flags persist across
                    // launches and the app has no record of what a previous install wrote. Wear is NOT
                    // required: the on-wrist gate exists because the R22 STREAM is on-wrist only.
                    NoopButton(
                        text = uiString(R.string.l10n_settings_screen_turn_deep_data_back_off_r22disable),
                        leadingIcon = Icons.Filled.Cancel,
                        kind = NoopButtonKind.Secondary,
                        enabled = live.encryptedBond && r22DisableReport != WhoopBleClient.WAITING_DEVICE_CONFIG_PROBE,
                        onClick = { vm.ble.disableWhoop5DeepData() },
                    )
                    Text(
                        if (!live.encryptedBond) uiString(R.string.l10n_settings_screen_r22disable_needs_bond)
                        else uiString(R.string.l10n_settings_screen_r22disable_reason),
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )
                    // Live R22 telemetry (#174): proof of what the strap is doing right now. The threshold
                    // and the number are both driven off the sequence itself — they were hardcoded to 15
                    // while the sequence carried 16, so the card declared success one flag early.
                    if (live.r22FlagsAccepted > 0) {
                        Text(
                            if (live.r22FlagsAccepted >= r22FlagCount) {
                                uiString(R.string.l10n_settings_screen_r22_accepted_all, r22FlagCount)
                            } else {
                                uiString(R.string.l10n_settings_screen_r22_accepted_partial, live.r22FlagsAccepted, r22FlagCount)
                            },
                            style = NoopType.caption,
                            color = if (live.r22FlagsAccepted >= r22FlagCount) Palette.statusPositive else Palette.textSecondary,
                        )
                    }
                    if (live.deepPacketsThisSession > 0) {
                        Text(
                            uiString(R.string.l10n_settings_screen_live_deeppacketsthissession_type_0x2f_historical_offload_8fef3d84, live.deepPacketsThisSession),
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                        )
                    } else if (live.r22FlagsAccepted >= r22FlagCount) {
                        Text(
                            uiString(R.string.l10n_settings_screen_flags_accepted_but_the_enable_sequence_542b2595),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }

                }

                // #174: the disable run's per-key result. Shown verbatim because the interesting part
                // is the read-back table, not a green tick — a write that acked SUCCESS but did not
                // move the stored value renders here as "unchanged", which is the case worth seeing.
                //
                // OUTSIDE the `if (deepData)` block on purpose. The commonest way to reach a disable run is
                // flipping the switch OFF and confirming, which means the pref is already false while the
                // run is walking its plan — so nesting this inside that block hid the progress line and the
                // whole read-back table for exactly the run a user is most likely to start. The report is
                // about what is on the STRAP, which outlives the app's opt-in.
                val disableReport = r22DisableReport
                if (disableReport != null) {
                    if (disableReport == WhoopBleClient.WAITING_DEVICE_CONFIG_PROBE) {
                        Text(
                            uiString(R.string.l10n_settings_screen_r22disable_running),
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                        )
                    } else {
                        Text(
                            disableReport,
                            style = NoopType.caption.copy(fontFamily = FontFamily.Monospace),
                            color = Palette.textSecondary,
                        )
                        NoopButton(
                            text = uiString(R.string.l10n_settings_screen_r22disable_dismiss),
                            kind = NoopButtonKind.Secondary,
                            onClick = { vm.ble.clearR22DisableReport() },
                        )
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        uiString(R.string.l10n_settings_screen_record_5_mg_raw_capture_research_1d966bbf),
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = puffinCapture,
                        onCheckedChange = {
                            puffinCapture = it
                            puffinExperiment.isCaptureEnabled = it
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = uiString(R.string.l10n_settings_screen_record_5_mg_raw_capture_9354fe89)
                        },
                    )
                }
                Text(
                    uiString(R.string.l10n_settings_screen_records_the_raw_frames_of_each_98a284df),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
                NoopButton(
                    text = uiString(R.string.l10n_settings_screen_share_5_mg_capture_for_the_e41ac6bd),
                    leadingIcon = Icons.Filled.Upload,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = !whoop5CaptureBusy,
                    onClick = {
                        whoop5CaptureBusy = true
                        scope.launch {
                            // try/finally: the flag must clear on any exit, not just the happy path (#961 follow-up).
                            try {
                                LogExport.shareWhoop5Capture(context, live.whoop5Detected)
                            } finally {
                                whoop5CaptureBusy = false
                            }
                        }
                    },
                )
                if (whoop5CaptureBusy) {
                    NoopBusyRow()
                }

                // One-tap "matched pair" export (#510): hands a reporter BOTH the raw capture file and
                // the strap log together (timestamped, same minute) so a protocol-mapping issue arrives
                // with the frames AND the context that produced them.
                NoopButton(
                    text = uiString(R.string.l10n_settings_screen_export_raw_log_matched_pair_d65390bf),
                    leadingIcon = Icons.Filled.IosShare,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = !rawAndLogBusy,
                    onClick = {
                        rawAndLogBusy = true
                        scope.launch {
                            // try/finally: the flag must clear on any exit, not just the happy path (#961 follow-up).
                            try {
                                LogExport.shareRawAndLog(context, vm.ble.exportLogText(), live.whoop5Detected)
                            } finally {
                                rawAndLogBusy = false
                            }
                        }
                    },
                )
                if (rawAndLogBusy) {
                    NoopBusyRow()
                }
            }
        }
        } // end if (showFiveMGControls)

        // --- Diagnostics (every model) --- the raw-sensor CSV export is split out of the 5/MG card so it
        // stays available on a WHOOP 4.0 too (#22): a 4.0 owner still needs it to share decoded streams.
        SettingsCard(
            icon = Icons.Filled.Science,
            title = uiString(R.string.l10n_settings_screen_diagnostics_3af2279f),
            blurb = "A read-only export of the decoded sensor streams NOOP already stores. Works on any strap. Nothing is written to your device, and nothing is uploaded.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                // --- Sleep staging (V2) — the DEFAULT engine after the 44-subject benchmark; toggle off to
                //     fall back to V1. Every model. (V7 Pillar 3b) ---
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        uiString(R.string.l10n_settings_screen_sleep_staging_v2_a4176770),
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = experimentalSleepV2,
                        onCheckedChange = {
                            experimentalSleepV2 = it
                            puffinExperiment.experimentalSleepV2 = it
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = uiString(R.string.l10n_settings_screen_sleep_staging_v2_3a007e4a)
                        },
                    )
                }
                Text(
                    uiString(R.string.l10n_settings_screen_a_transparent_cardiorespiratory_recipe_that_recovers_eebe00c2) +
                        "V1 staging, and is now the default. It only changes how already-detected nights are " +
                        "split into stages (detection and scores are unchanged); turn it off to fall back to " +
                        "V1. Takes effect on the next nights staged.",
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )

                // --- Motion-aware wake refinement (#364 follow-up) — OFF by default. ---
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        uiString(R.string.l10n_settings_screen_motion_aware_wake_refinement_67a91e47),
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = motionAwareWake,
                        onCheckedChange = {
                            motionAwareWake = it
                            puffinExperiment.motionAwareWake = it
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = uiString(R.string.l10n_settings_screen_motion_aware_wake_refinement_67a91e47)
                        },
                    )
                }
                Text(
                    uiString(R.string.l10n_settings_screen_reviews_each_scored_wake_block_for_537924ea) +
                        "change in body position) instead of just a heart-rate rise. A wake block with no " +
                        "locomotion and a stable posture -- a hot night, a brief turn-over -- is folded back " +
                        "into light sleep; a real get-up is left alone. Self-checks how much motion detail " +
                        "your strap actually recorded and stays off on a night that's too sparse to trust " +
                        "(older WHOOP 4.0 firmware, mainly). Off by default; takes effect on the next nights staged.",
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )

                // Diagnostics: dump the decoded per-sample sensor streams (last 24h) to one long-format
                // CSV so power users / external devs can prototype sleep/activity/VBT algorithms on real
                // data without a BLE stream (#308/#276/#322). On-device only; plain text, no BLE hex.
                NoopButton(
                    text = uiString(R.string.l10n_settings_screen_export_raw_sensor_data_csv_a171b81e),
                    leadingIcon = Icons.Filled.Upload,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    onClick = { scope.launch { RawSensorExport.export(context, vm.repo, vm.activeStrapId) } },
                )
                Text(
                    uiString(R.string.l10n_settings_screen_saves_the_last_24h_of_decoded_f7026f47),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )

                // Haptic clock (#460): buzz the current time on the strap as a sequence of buzzes. No-ops
                // safely when disconnected, so it stays enabled regardless of connection (matches the
                // "Share strap log" row above, which also doesn't gate on a live strap). 12/24h follows the
                // phone's own clock setting.
                NoopButton(
                    text = uiString(R.string.l10n_settings_screen_buzz_the_time_on_your_strap_06fc879d),
                    leadingIcon = Icons.Filled.Vibration,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    onClick = {
                        vm.ble.buzzTimeNow(is24h = android.text.format.DateFormat.is24HourFormat(context))
                    },
                )
                Text(
                    uiString(R.string.l10n_settings_screen_feel_the_current_time_as_a_8ca41db1),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }

        // --- Trends report (#436) — shareable offline PDF over a date range. Self-contained
        // card (its own NoopCard + range picker + CTA), so it drops in without a SettingsSection wrapper.
        TrendsReportExportSection(vm)
        } // end Advanced disclosure content Column
        } // end SettingsDisclosureGroup("Advanced")

        // --- Health & wellness (v5 opt-in toggles) ---
        SettingsCard(
            icon = Icons.Filled.Science,
            title = uiString(R.string.l10n_settings_screen_health_wellness_93475778),
            blurb = "Optional, on-device wellness signals. Each is off by default, computed only on this phone from data you already have, and never a medical diagnosis.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                SettingsToggleRow(
                    title = uiString(R.string.l10n_settings_screen_illness_heads_up_97e10035),
                    detail = "Watches your resting heart rate, HRV and skin temperature for the pattern that often shows up before you feel unwell, and surfaces a gentle heads-up. An observation about your own numbers, not a diagnosis.",
                    checked = illnessWatch,
                    onCheckedChange = {
                        illnessWatch = it
                        vm.setIllnessWatchEnabled(it)
                    },
                )
                SettingsRowDivider()
                // #801 — not offered on a male profile (it would just sit at "Learning your pattern"). Hidden
                // when off for a male profile so it can't be enabled here; still shown when already on so it
                // can be turned off — mirroring HealthScreen's cycle opt-in gate (cycleOptInApplies). The
                // sister surfaces (Health opt-in, the card's off-control) were sex-gated in v7.3.2; this
                // Settings toggle was the one surface that was missed, so a male profile could enable it here.
                if (cycleTracking || cycleOptInApplies(profile.sex)) {
                    SettingsToggleRow(
                        title = uiString(R.string.l10n_settings_screen_cycle_awareness_ffb94783),
                        detail = "Reads a coarse menstrual-cycle phase from your nightly skin-temperature shift, on this device only. Awareness only: not contraception, not a fertility predictor, not a medical service.",
                        checked = cycleTracking,
                        onCheckedChange = {
                            cycleTracking = it
                            vm.setCycleTrackingEnabled(it)
                        },
                    )
                    SettingsRowDivider()
                }
                SettingsToggleRow(
                    title = uiString(R.string.l10n_settings_screen_hydration_tracking_579a2b32),
                    detail = "Adds a simple fluid log with a daily goal that adjusts to your effort. Tap to add a sip, cup or bottle and watch a progress ring fill. On this phone only. Nothing is synced.",
                    checked = hydrationTracking,
                    onCheckedChange = {
                        hydrationTracking = it
                        NoopPrefs.setHydrationTracking(context, it)
                    },
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    title = uiString(R.string.l10n_settings_screen_auto_detect_workouts_bed4cf2a),
                    detail = "After a sync, NOOP looks over your recent heart rate for a sustained, raised stretch that looks like exercise and offers to save it. It only ever suggests. Nothing is saved until you tap Save, and you can dismiss any suggestion. Deliberately conservative, so the odd workout may be missed. On this phone only.",
                    checked = autoDetectWorkouts,
                    onCheckedChange = {
                        autoDetectWorkouts = it
                        NoopPrefs.setAutoDetectWorkouts(context, it)
                    },
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    title = uiString(R.string.l10n_journal_reminder_journal_reminder_0fdc0d9c),
                    detail = uiString(R.string.l10n_journal_reminder_show_a_today_card_reminding_you_to_log_your_journal_8228bc77),
                    checked = journalReminder,
                    onCheckedChange = {
                        journalReminder = it
                        NoopPrefs.setJournalReminderEnabled(context, it)
                    },
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    title = uiString(R.string.l10n_settings_screen_keep_screen_on_during_a_workout_42d27284),
                    detail = "Holds the screen awake while you're recording a workout, so your live heart rate stays visible without the phone dimming. Only applies during a recording. The screen sleeps normally the rest of the time. Leaving it on does use a bit more battery, and means your unlocked screen stays visible for the whole workout, so flip it off if that's a concern.",
                    checked = workoutKeepScreenOn,
                    onCheckedChange = {
                        workoutKeepScreenOn = it
                        NoopPrefs.of(context).edit().putBoolean("workoutKeepScreenOn", it).apply()
                    },
                )
                SettingsRowDivider()
                // BETA + default ON (the one exception to this section's off-by-default rule): the flag
                // gates the Today entry so anyone can wave the beta away here with one flip.
                SettingsToggleRow(
                    title = uiString(R.string.l10n_settings_screen_live_sessions_beta_2ca3a97f),
                    detail = "Silence-first strap coaching during workouts.",
                    checked = liveSessionsBeta,
                    onCheckedChange = {
                        liveSessionsBeta = it
                        LiveSessionPrefs.setEnabled(context, it)
                    },
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    title = uiString(R.string.l10n_settings_screen_stress_check_ins_haptic_bf2746ba),
                    detail = "Lets NOOP notice a fresh HRV dip while you're still and offer a minute to breathe. \"Stress\" here is an autonomic proxy from your own baseline, never a diagnosis. The strap gives one light confirming buzz; no push notification.",
                    checked = stressCheckIn,
                    onCheckedChange = {
                        stressCheckIn = it
                        BiofeedbackPrefs.setCheckInEnabled(context, it)
                        // Turning the master off also disarms the auto-nudge sub-toggle so it can't fire.
                        if (!it) { stressAutoNudge = false; BiofeedbackPrefs.setAutoNudge(context, false) }
                    },
                )
                if (stressCheckIn) {
                    SettingsToggleRow(
                        title = uiString(R.string.l10n_settings_screen_offer_a_breath_automatically_6c709dee),
                        detail = "When a dip is detected, surface the check-in card on its own (rate-limited, quiet-hours aware). Off keeps it manual.",
                        checked = stressAutoNudge,
                        onCheckedChange = {
                            stressAutoNudge = it
                            BiofeedbackPrefs.setAutoNudge(context, it)
                        },
                    )
                }
                SettingsRowDivider()
                SettingsToggleRow(
                    title = uiString(R.string.l10n_settings_screen_rhythm_experimental_12d357da),
                    detail = "An experimental picture of your beat-to-beat timing: a Poincaré scatter and plain regularity stats from quiet resting windows. Not an ECG and not a diagnosis; you'll read a short disclaimer and accept before it turns on.",
                    checked = rhythmEnabled,
                    onCheckedChange = {
                        // Enabling here just un-gates the experimental item; the screen itself still shows
                        // its consent clickwrap on first open (and re-prompts on a version bump). Disabling
                        // clears the flag so the screen returns to its gate.
                        rhythmEnabled = it
                        if (it) {
                            NoopPrefs.of(context).edit().putBoolean(RhythmConsent.KEY_ENABLED, true).apply()
                        } else {
                            NoopPrefs.of(context).edit().putBoolean(RhythmConsent.KEY_ENABLED, false).apply()
                        }
                    },
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    title = uiString(R.string.l10n_settings_screen_share_on_device_signals_with_the_b3fd747e),
                    detail = "When the opt-in Coach is set up with your own key, also include a short summary of your strongest on-device patterns and Lab Book markers in its context. Summary only; no raw data leaves your phone. Requires the Coach's own data consent first.",
                    checked = coachSignals,
                    onCheckedChange = {
                        coachSignals = it
                        NoopPrefs.setCoachSignals(context, it)
                    },
                )
            }
        }

        // --- Test Centre (the diagnostic home, #507/#509) ---
        // A nav row into the Test Centre: the single home for the diagnostic, log and test controls (spec
        // section 7). The strap log, recalibrate, scheduled export and experimental toggles also live there
        // on the same bindings, so this is a faster door to the full set without growing this screen.
        SettingsCard(
            icon = Icons.Filled.BugReport,
            title = uiString(R.string.l10n_settings_screen_test_centre_37b36828),
            blurb = "Turn on a test for the thing that's wrong, wear the strap, then tap Report. Your strap log, recalibrate, scheduled export and experimental probes all live here too.",
        ) {
            NoopButton(
                text = uiString(R.string.l10n_settings_screen_open_test_centre_a7fbe4e9),
                leadingIcon = Icons.Filled.BugReport,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                onClick = onOpenTestCentre,
            )
        }

        // --- Charge (Recovery) advanced ---
        // A manual reset for the personal Charge baseline. If a bad first week poisons it — worn while
        // sick, or the first few nights read high (a common cold-start artefact) — the baseline anchors
        // off and holds your Charge wrong for a couple of weeks while the rolling average catches up.
        // Recalibrate re-learns it from tonight onward. Writes now-seconds to BOTH noop.hrvBaselineEpoch
        // and noop.recoveryBaselineEpoch (so HRV plus resting HR / respiration / skin temp re-anchor);
        // foldHistory drops every night before that epoch and re-seeds. Mirrors the iOS/Mac button.
        SettingsCard(
            icon = Icons.Filled.Favorite,
            title = uiString(R.string.l10n_settings_screen_charge_d4e1aee4),
            blurb = "Charge is NOOP's daily readiness score, learned from your own HRV, resting heart rate and more over time. Your history stays.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(uiString(R.string.l10n_settings_screen_recalibrate_charge_baseline_52a05a26), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.l10n_settings_screen_restarts_the_roughly_4_night_build_84f9f8d0),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                NoopButton(
                    text = uiString(R.string.l10n_settings_screen_recalibrate_charge_baseline_52a05a26),
                    leadingIcon = Icons.Filled.Autorenew,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_settings_screen_recalibrate_charge_baseline_52a05a26) },
                    onClick = { showRecalibrateConfirm = true },
                )
            }
        }

        // #174: the switch going OFF is the moment to offer the undo. Declining leaves the flags set and
        // says so — still an improvement on the old behaviour, where the same tap silently left them set
        // with no indication either way.
        if (confirmingDeepDataDisable) {
            AlertDialog(
                onDismissRequest = { confirmingDeepDataDisable = false },
                containerColor = Palette.surfaceOverlay,
                title = {
                    Text(
                        uiString(R.string.l10n_settings_screen_r22disable_confirm_title),
                        style = NoopType.title2,
                        color = Palette.textPrimary,
                    )
                },
                text = {
                    Text(
                        uiString(R.string.l10n_settings_screen_r22disable_confirm_body),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                },
                confirmButton = {
                    TextButton(onClick = {
                        confirmingDeepDataDisable = false
                        vm.ble.disableWhoop5DeepData()
                    }) {
                        Text(
                            uiString(R.string.l10n_settings_screen_r22disable_confirm_action),
                            color = Palette.accent,
                        )
                    }
                },
                dismissButton = {
                    TextButton(onClick = { confirmingDeepDataDisable = false }) {
                        Text(
                            uiString(R.string.l10n_settings_screen_r22disable_confirm_cancel),
                            color = Palette.textSecondary,
                        )
                    }
                },
            )
        }

        if (showRecalibrateConfirm) {
            AlertDialog(
                onDismissRequest = { showRecalibrateConfirm = false },
                containerColor = Palette.surfaceOverlay,
                title = { Text(uiString(R.string.l10n_settings_screen_recalibrate_your_charge_baseline_018e3846), style = NoopType.title2, color = Palette.textPrimary) },
                text = {
                    Text(
                        uiString(R.string.l10n_settings_screen_this_restarts_the_roughly_4_night_c610a93d),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                },
                confirmButton = {
                    TextButton(
                        onClick = {
                            // Re-anchor EVERY baseline that feeds Charge — HRV plus resting HR /
                            // respiration / skin temp — by writing now-seconds to BOTH shared epoch keys
                            // (the EXACT same keys the iOS/Mac button + Baselines.foldHistory use), via
                            // the single cross-platform source of truth. Stored as whole epoch SECONDS in
                            // a Long (SharedPreferences has no putDouble; the readers do getLong→toDouble),
                            // matching the "epoch SECONDS" the keys document. No stored day is deleted.
                            val nowSeconds = System.currentTimeMillis() / 1000L
                            val editor = NoopPrefs.of(context).edit()
                            Baselines.recalibrateRecoveryBaselines(editor, nowSeconds)
                            editor.apply()
                            showRecalibrateConfirm = false
                            // Nudge an immediate re-analyze so the change is felt now; the standing
                            // 15-min analyze loop also re-runs foldHistory regardless. No-ops cleanly
                            // when the strap isn't connected.
                            vm.syncNow()
                            Toast.makeText(
                                context,
                                "Charge baseline reset. NOOP will re-learn it from tonight. Your history stays, and it takes a few nights to settle.",
                                Toast.LENGTH_LONG,
                            ).show()
                        },
                    ) { Text(uiString(R.string.l10n_settings_screen_recalibrate_aaa989ea), style = NoopType.body, color = Palette.accent) }
                },
                dismissButton = {
                    TextButton(onClick = { showRecalibrateConfirm = false }) {
                        Text(uiString(R.string.l10n_settings_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
                    }
                },
            )
        }

        SettingsCard(
            icon = Icons.Filled.Storage,
            title = uiString(R.string.l10n_settings_screen_backup_restore_a1616284),
            blurb = "Move all your NOOP data to another phone. Export saves everything (history, sleeps, workouts, settings) to a single file you can copy across; import replaces this phone's data with a backup.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                // Three equal-width buttons share the row (each takes a third via weight) — mirrors the
                // iOS Backup card's three fullWidth NoopButtonStyle buttons. The busy spinner sits BELOW
                // the row (not inside it) so it never steals a button's share of the width.
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    NoopButton(
                        text = uiString(R.string.l10n_settings_screen_export_0a116345),
                        kind = NoopButtonKind.Primary,
                        enabled = !backupBusy,
                        modifier = Modifier.weight(1f),
                        onClick = {
                            backupBusy = true
                            exportLauncher.launch("noop-backup-${java.time.LocalDate.now()}.noopbak")
                        },
                    )

                    NoopButton(
                        text = uiString(R.string.l10n_settings_screen_import_4834caf8),
                        kind = NoopButtonKind.Secondary,
                        enabled = !backupBusy,
                        modifier = Modifier.weight(1f),
                        onClick = {
                            backupBusy = true
                            importLauncher.launch(arrayOf("*/*"))
                        },
                    )

                    NoopButton(
                        text = uiString(R.string.l10n_settings_screen_export_csv_6bce63a3),
                        kind = NoopButtonKind.Secondary,
                        enabled = !backupBusy,
                        modifier = Modifier.weight(1f),
                        onClick = {
                            backupBusy = true
                            csvExportLauncher.launch("noop-export-${java.time.LocalDate.now()}.zip")
                        },
                    )
                }

                if (backupBusy) {
                    NoopBusyRow()
                }

                SettingsNoteRow(
                    icon = Icons.Filled.Info,
                    iconTint = Palette.textTertiary,
                    text = uiString(R.string.l10n_settings_screen_importing_overwrites_everything_currently_on_this_297b76ae) +
                        "Export CSV writes a WHOOP-format zip of your days, sleeps, workouts and journal that re-imports into NOOP on Android or Mac. On-device computed rows are marked APPROXIMATE in its Source column; the .noopbak backup stays the lossless restore path.",
                )

                // #644: .noopbak is a plain ZIP, not an encrypted container — anyone who gets the file
                // can open it in any archive tool. Surface that plainly, right next to the Export
                // button, rather than let people assume the file itself is protected once it leaves
                // the device (e.g. dropped into a cloud-synced folder).
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics(mergeDescendants = true) {},
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(
                        Icons.Filled.Warning,
                        contentDescription = null,
                        tint = Palette.statusWarning,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(
                        uiString(R.string.l10n_settings_screen_this_is_a_plain_unencrypted_archive_b0dfe63d),
                        style = NoopType.caption,
                        color = Palette.statusWarning,
                    )
                }
            }
        }

        // --- Automatic backups ---
        // Discoverability signpost: the daily-backup toggle, folder picker and keep-count live on the
        // separate Backup & Sync screen; surface an entry here, right under the one-off Backup & restore,
        // since that's where a user looks for "turn on automatic backups".
        SettingsCard(
            icon = Icons.Filled.CloudSync,
            title = uiString(R.string.l10n_settings_screen_automatic_backups_8a772f3c),
            blurb = "Have NOOP save a dated backup to a folder every day (around 1am) and keep the last several - so if data ever corrupts, restore the newest. Point the folder at Drive/Dropbox for off-device copies. Off until you switch it on.",
        ) {
            NoopButton(
                text = uiString(R.string.l10n_settings_screen_set_up_automatic_backups_00b4780c),
                leadingIcon = Icons.Filled.CloudSync,
                kind = NoopButtonKind.Primary,
                fullWidth = true,
                onClick = onOpenBackupSync,
            )
        }

        // --- About ---
        SettingsCard(
            icon = Icons.Filled.Info,
            title = uiString(R.string.l10n_settings_screen_about_6b21fb79),
            blurb = "NOOP: all your data, none of the cloud.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text("NOOP", style = NoopType.title2, color = Palette.textPrimary)
                    StatePill("v${BuildConfig.VERSION_NAME}", tone = StrandTone.Neutral, showsDot = false)
                }

                // Project home — NOOP's code, releases, issues and wiki live on GitHub.
                val projectHomeInteraction = remember { MutableInteractionSource() }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .liquidPress(projectHomeInteraction)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.accent.copy(alpha = 0.10f))
                        .border(1.dp, Palette.accent.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
                        .clickable(
                            interactionSource = projectHomeInteraction,
                            indication = null,
                        ) {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/ryanbr/noop"))
                            try {
                                context.startActivity(intent)
                            } catch (_: ActivityNotFoundException) {
                                Toast.makeText(context, "github.com/ryanbr/noop", Toast.LENGTH_LONG).show()
                            }
                        }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                        .semantics { contentDescription = uiString(R.string.l10n_settings_screen_project_home_and_source_on_github_a067ed35) },
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(uiString(R.string.l10n_settings_screen_project_home_source_994627c1), style = NoopType.body, color = Palette.textPrimary)
                        Text(
                            uiString(R.string.l10n_settings_screen_github_code_releases_issues_and_the_50b41e25),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                }

                // Check for updates — a single, user-initiated call to the project's public releases API (GitHub)
                // when the button is tapped. No background polling, no auto-update; nothing about you
                // is sent. Android already holds INTERNET (for the opt-in Coach), so this adds nothing.
                var updChecking by remember { mutableStateOf(false) }
                var updResult by remember { mutableStateOf<UpdateCheck.Result?>(null) }
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        OutlinedButton(
                            onClick = {
                                if (!updChecking) {
                                    updChecking = true
                                    updResult = null
                                    scope.launch {
                                        updResult = UpdateCheck.check(BuildConfig.VERSION_NAME)
                                        updChecking = false
                                    }
                                }
                            },
                            enabled = !updChecking,
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                        ) {
                            if (updChecking) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(14.dp).padding(end = 6.dp),
                                    strokeWidth = 2.dp,
                                    color = Palette.accent,
                                )
                                Text(uiString(R.string.l10n_settings_screen_checking_820d6004), style = NoopType.captionNumber)
                            } else {
                                Text(uiString(R.string.l10n_settings_screen_check_for_updates_736b9062), style = NoopType.captionNumber)
                            }
                        }
                        when (val r = updResult) {
                            is UpdateCheck.Result.UpToDate ->
                                Text(
                                    uiString(R.string.l10n_settings_screen_you_re_on_the_latest_r_027a82be, r.version),
                                    style = NoopType.footnote, color = Palette.textSecondary,
                                )
                            UpdateCheck.Result.Failed ->
                                Text(
                                    uiString(R.string.l10n_settings_screen_couldn_t_check_try_again_b3c885d9),
                                    style = NoopType.footnote, color = Palette.statusWarning,
                                )
                            else -> {}
                        }
                    }

                    // Update available: show what's new, with a download straight to the release.
                    (updResult as? UpdateCheck.Result.Available)?.let { avail ->
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(Palette.surfaceInset)
                                .border(1.dp, Palette.accent.copy(alpha = 0.3f), RoundedCornerShape(10.dp))
                                .padding(12.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    uiString(R.string.l10n_settings_screen_version_avail_version_is_available_5b401bd4, avail.version),
                                    style = NoopType.subhead, color = Palette.textPrimary,
                                    modifier = Modifier.weight(1f),
                                )
                                NoopButton(
                                    text = uiString(R.string.l10n_settings_screen_download_a479c9c3),
                                    leadingIcon = Icons.Filled.Download,
                                    kind = NoopButtonKind.Primary,
                                    onClick = {
                                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(avail.url)))
                                    },
                                )
                            }
                            if (avail.notes.isNotEmpty()) {
                                Text(
                                    avail.notes,
                                    style = NoopType.footnote, color = Palette.textSecondary,
                                    modifier = Modifier
                                        .heightIn(max = 160.dp)
                                        .verticalScroll(rememberScrollState()),
                                )
                            }
                        }
                    }

                    Text(
                        uiString(R.string.l10n_settings_screen_checks_github_for_the_latest_version_c10a81e2),
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }

                Text(
                    uiString(R.string.l10n_settings_screen_a_standalone_companion_for_your_whoop_7a132b5a),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )

                // What's new — re-open the changelog sheet any time (macOS About parity).
                val whatsNewInteraction = remember { MutableInteractionSource() }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .liquidPress(whatsNewInteraction)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.surfaceInset)
                        .border(1.dp, Palette.hairline, RoundedCornerShape(10.dp))
                        .clickable(
                            interactionSource = whatsNewInteraction,
                            indication = null,
                        ) { showWhatsNew = true }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                        .semantics { contentDescription = uiString(R.string.l10n_settings_screen_what_s_new_in_noop_appchangelog_d26fb453, AppChangelog.CURRENT_VERSION) },
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            Icons.Filled.Campaign,
                            contentDescription = null,
                            tint = Palette.accent,
                            modifier = Modifier.size(18.dp),
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text(uiString(R.string.l10n_settings_screen_what_s_new_4d8dc5fe), style = NoopType.headline, color = Palette.textPrimary)
                            Text(
                                uiString(R.string.l10n_settings_screen_recent_changes_and_what_to_expect_3ceb660b),
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                        Text("›", style = NoopType.title2, color = Palette.accent)
                    }
                }

                // How your scores work — the honest explainer for Charge/Effort/Rest + the
                // confidence labels, opened any time (macOS/iOS About parity).
                val scoringGuideInteraction = remember { MutableInteractionSource() }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .liquidPress(scoringGuideInteraction)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.surfaceInset)
                        .border(1.dp, Palette.hairline, RoundedCornerShape(10.dp))
                        .clickable(
                            interactionSource = scoringGuideInteraction,
                            indication = null,
                        ) { showScoringGuide = true }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                        .semantics { contentDescription = uiString(R.string.l10n_settings_screen_how_your_scores_work_21a0e2be) },
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            Icons.Filled.Science,
                            contentDescription = null,
                            tint = Palette.accent,
                            modifier = Modifier.size(18.dp),
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text(uiString(R.string.l10n_settings_screen_how_your_scores_work_21a0e2be), style = NoopType.headline, color = Palette.textPrimary)
                            Text(
                                uiString(R.string.l10n_settings_screen_charge_effort_and_rest_and_how_d2c423a4),
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                        Text("›", style = NoopType.title2, color = Palette.accent)
                    }
                }

                // How NOOP works — the plain-English primer (COMPONENT 5 of the explainability layer):
                // how sleep is sorted, how scores + calibration work, what recording means, and where
                // each number comes from. The one "?" entry point into the primer (macOS/iOS parity).
                val howNoopWorksInteraction = remember { MutableInteractionSource() }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .liquidPress(howNoopWorksInteraction)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.surfaceInset)
                        .border(1.dp, Palette.hairline, RoundedCornerShape(10.dp))
                        .clickable(
                            interactionSource = howNoopWorksInteraction,
                            indication = null,
                        ) { showHowNoopWorks = true }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                        .semantics { contentDescription = uiString(R.string.l10n_settings_screen_how_noop_works_3396b27a) },
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            Icons.AutoMirrored.Filled.MenuBook,
                            contentDescription = null,
                            tint = Palette.accent,
                            modifier = Modifier.size(18.dp),
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text(uiString(R.string.l10n_settings_screen_how_noop_works_3396b27a), style = NoopType.headline, color = Palette.textPrimary)
                            Text(
                                uiString(R.string.l10n_settings_screen_sleep_sorting_scores_recording_and_where_832378b5),
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                        Text("›", style = NoopType.title2, color = Palette.accent)
                    }
                }

                // Medical disclaimer — inset well with a warning-tinted hairline.
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.surfaceInset)
                        .border(1.dp, Palette.statusWarning.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        Icons.Filled.Info,
                        contentDescription = null,
                        tint = Palette.statusWarning,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(
                        uiString(R.string.l10n_settings_screen_noop_is_not_a_medical_device_ab32ef7e),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }

                SettingsRowDivider()

                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Overline("Built on")
                    SettingsAttributionRow(repo = "my-whoop", note = "WHOOP 4.0 protocol")
                    SettingsAttributionRow(repo = "goose", note = "WHOOP 5.0 protocol")
                }
                Text(
                    uiString(R.string.l10n_settings_screen_open_source_ble_reverse_engineering_work_40062271),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )

                SettingsRowDivider()

                // Support link — opens the project's contact email (same address the
                // Support screen lists). NOOP is anonymous, so email is the support channel.
                val supportInteraction = remember { MutableInteractionSource() }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .liquidPress(supportInteraction)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.accent.copy(alpha = 0.10f))
                        .border(1.dp, Palette.accent.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
                        .clickable(
                            interactionSource = supportInteraction,
                            indication = null,
                        ) {
                            val intent = Intent(Intent.ACTION_SENDTO).apply {
                                data = Uri.parse("mailto:$SUPPORT_EMAIL")
                                putExtra(Intent.EXTRA_SUBJECT, "NOOP support")
                            }
                            try {
                                context.startActivity(intent)
                            } catch (_: ActivityNotFoundException) {
                                Toast.makeText(context, "Email us at $SUPPORT_EMAIL", Toast.LENGTH_LONG).show()
                            }
                        }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                        .semantics { contentDescription = uiString(R.string.l10n_settings_screen_contact_support_at_support_email_f0c4adce, SUPPORT_EMAIL) },
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(uiString(R.string.l10n_settings_screen_support_contact_f4c31b01), style = NoopType.headline, color = Palette.textPrimary)
                            Text(
                                uiString(R.string.l10n_settings_screen_questions_feedback_bugs_support_email_ed10662a, SUPPORT_EMAIL),
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                        Text("›", style = NoopType.title2, color = Palette.accent)
                    }
                }
            }
        }

        // What's new sheet, opened from the About row above. Full-screen Dialog so it
        // covers the whole screen like the macOS .sheet; closing just hides it.
        if (showWhatsNew) {
            Dialog(
                onDismissRequest = { showWhatsNew = false },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                    WhatsNewSheet(onClose = { showWhatsNew = false })
                }
            }
        }

        // Scoring guide sheet, opened from the About row above. Same full-screen Dialog idiom.
        if (showScoringGuide) {
            Dialog(
                onDismissRequest = { showScoringGuide = false },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                    ScoringGuideScreen(onClose = { showScoringGuide = false })
                }
            }
        }

        // "How NOOP works" primer sheet, opened from the About row above. Same full-screen Dialog idiom.
        if (showHowNoopWorks) {
            Dialog(
                onDismissRequest = { showHowNoopWorks = false },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                    HowNoopWorksScreen(onClose = { showHowNoopWorks = false })
                }
            }
        }

        // "WHOOP 4.0 vs 5.0/MG" explainer sheet (FI-2 / #490), opened from the Strap section. Same idiom.
        if (showModelComparison) {
            Dialog(
                onDismissRequest = { showModelComparison = false },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                    WhoopModelComparisonScreen(onClose = { showModelComparison = false })
                }
            }
        }


        // Steps-estimate calibration, opened from the Profile card's "Steps estimate" row. Same
        // full-screen Dialog idiom; a manual-coefficient write bumps `rev` so the Profile summary
        // row reflects the new state on dismiss.
        if (showStepsCalibration) {
            Dialog(
                onDismissRequest = { showStepsCalibration = false },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                    StepsCalibrationScreen(
                        vm = vm,
                        profile = profile,
                        onProfileChanged = { rev++ },
                        onClose = { showStepsCalibration = false },
                    )
                }
            }
        }
    }
}

private const val SUPPORT_EMAIL = "thenoopapp@gmail.com"

// MARK: - App icon swap (v3 "Titanium & Gold")

/**
 * The two launcher-icon aliases declared in AndroidManifest.xml. Exactly one is ever enabled — the
 * enabled one is the app's home-screen entry point and supplies the launcher icon.
 */
private const val ALIAS_DEFAULT = "com.noop.IconDefault" // machined titanium
private const val ALIAS_NAVY = "com.noop.IconNavy"       // blued / dark-blue titanium

/**
 * Persist the chosen launcher icon and flip the manifest aliases so exactly one is enabled:
 * [navy] true enables `.IconNavy` and disables `.IconDefault`, false does the inverse. We use
 * DONT_KILL_APP so the toggle doesn't tear down our own process. The home launcher may briefly hide
 * and redraw the icon (or take a few seconds) while it re-reads the component state — that's expected
 * and is the only user-visible side effect.
 */
private fun setAppIcon(context: Context, navy: Boolean) {
    NoopPrefs.setAppIconNavy(context, navy)
    val pm = context.packageManager
    pm.setComponentEnabledSetting(
        ComponentName(context, ALIAS_NAVY),
        if (navy) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
        PackageManager.DONT_KILL_APP,
    )
    pm.setComponentEnabledSetting(
        ComponentName(context, ALIAS_DEFAULT),
        if (navy) PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        else PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
        PackageManager.DONT_KILL_APP,
    )
}

/** #accent: a compact RGB picker for the CUSTOM chrome accent — a live preview swatch + three channel
 *  sliders. Emits `#RRGGBB` on every change; the Palette accent updates live via [AccentPrefs]. Shown only
 *  when the accent picker is set to Custom. */
@Composable
private fun AccentCustomPicker(hex: String, onHexChange: (String) -> Unit) {
    val base = AccentColor.parseHex(hex, Color(0xFF149A78))
    var r by remember { mutableStateOf(base.red) }
    var g by remember { mutableStateOf(base.green) }
    var b by remember { mutableStateOf(base.blue) }
    fun emit() = onHexChange(
        String.format("#%02X%02X%02X", (r * 255).roundToInt(), (g * 255).roundToInt(), (b * 255).roundToInt()),
    )
    Column(
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(26.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color(r, g, b, 1f)),
        )
        AccentChannelSlider("R", r) { r = it; emit() }
        AccentChannelSlider("G", g) { g = it; emit() }
        AccentChannelSlider("B", b) { b = it; emit() }
    }
}

@Composable
private fun AccentChannelSlider(label: String, value: Float, onChange: (Float) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(label, style = NoopType.caption, color = Palette.textTertiary, modifier = Modifier.width(14.dp))
        Slider(
            value = value,
            onValueChange = onChange,
            colors = SliderDefaults.colors(
                thumbColor = Palette.accent,
                activeTrackColor = Palette.accent,
                inactiveTrackColor = Palette.surfaceInset,
            ),
            modifier = Modifier.weight(1f),
        )
    }
}
