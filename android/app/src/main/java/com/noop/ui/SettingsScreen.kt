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
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Brightness6
import androidx.compose.material.icons.filled.Campaign
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.BuildConfig
import com.noop.analytics.Zones
import com.noop.ble.PuffinExperiment
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

    var age: Int
        get() = prefs.getInt(KEY_AGE, 30).coerceIn(AGE_MIN, AGE_MAX)
        set(v) = prefs.edit().putInt(KEY_AGE, v.coerceIn(AGE_MIN, AGE_MAX)).apply()

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

    companion object {
        private const val PREFS = "noop_profile"
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
fun SettingsScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val live by vm.live.collectAsStateWithLifecycle()

    // The profile store is stable for the lifetime of this screen; a version counter
    // forces recomposition after each mutating write (SharedPreferences isn't reactive).
    val profile = remember { ProfileStore.from(context) }
    var rev by remember { mutableStateOf(0) }
    fun mutate(block: () -> Unit) { block(); rev++ }

    var backupBusy by remember { mutableStateOf(false) }

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

    // Steps-estimate calibration screen (WHOOP 4.0), reached from the Profile card's "Steps estimate"
    // tap-through. Mirrors the macOS StepsCalibrationSheet: honest explainer + current fit + a recent
    // estimated-vs-phone table + a manual coefficient override. Full-screen Dialog like the guide above.
    var showStepsCalibration by remember { mutableStateOf(false) }

    // EXPERIMENTAL WHOOP 5/MG protocol probes (off by default). Mirrors the macOS @AppStorage toggle;
    // SharedPreferences isn't reactive, so the Switch drives a local mutableState that the store reads.
    val puffinExperiment = remember { PuffinExperiment.from(context) }
    var puffinExperiments by remember { mutableStateOf(puffinExperiment.isEnabled) }
    var puffinCapture by remember { mutableStateOf(puffinExperiment.isCaptureEnabled) }
    var deepData by remember { mutableStateOf(puffinExperiment.isDeepDataEnabled) }
    var broadcastHr by remember { mutableStateOf(puffinExperiment.broadcastHr) }

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

    // "Continuous HRV capture" — hold the dense realtime stream armed 24/7 (better overnight HRV) at the
    // cost of more battery. Default OFF; only does anything with background connection on. Local mirror.
    var continuousHrv by remember { mutableStateOf(NoopPrefs.continuousHrv(context)) }

    // "Debug logging" — mirror the strap log to logcat (adb). Default OFF so normal users don't.
    var debugLogging by remember { mutableStateOf(NoopPrefs.debugLogging(context)) }

    // --- v5 Health & wellness toggle group. All SharedPreferences-backed (not reactive), so each Switch
    // drives a local mirror that writes straight through to the same keys the v5 engine readers use.
    // Illness watch routes through the ViewModel so the banner recomputes live; the rest are pref writes
    // the engines pick up on the next analytics pass / offload. All opt-in / safe-default per spec.
    var illnessWatch by remember { mutableStateOf(NoopPrefs.illnessWatch(context)) }
    var cycleTracking by remember { mutableStateOf(NoopPrefs.cycleTracking(context)) }
    var stressCheckIn by remember { mutableStateOf(BiofeedbackPrefs.checkInEnabled(context)) }
    var stressAutoNudge by remember { mutableStateOf(BiofeedbackPrefs.autoNudge(context)) }
    var rhythmEnabled by remember { mutableStateOf(RhythmConsent.isEnabled(context)) }
    var coachSignals by remember { mutableStateOf(NoopPrefs.coachSignals(context)) }

    // Scheduled debug export (#510) — the daily auto-export toggle + time-of-day. The settings object is
    // its own SharedPreferences store; SharedPreferences isn't reactive, so the Switch + TimeChip mirror
    // into local state and write straight through, then (re)schedule via DebugExportScheduler.
    val debugExportSettings = remember { DebugExportSettings.from(context) }
    var debugExportEnabled by remember { mutableStateOf(debugExportSettings.enabled) }
    var debugExportMinutes by remember { mutableStateOf(debugExportSettings.timeMinutes) }

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
                runCatching { WhoopCsvExporter.exportZip(context, uri, vm.repo) }
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

    ScreenScaffold(
        title = "Settings",
        subtitle = "Your numbers, your strap, and how NOOP works. All on this phone.",
    ) {
        // Read the revision counter so every profile write recomposes this subtree
        // (SharedPreferences is not observable; `mutate` bumps `rev` after each write).
        @Suppress("UNUSED_VARIABLE") val tick = rev

        // --- Profile ---
        SettingsSection(
            icon = Icons.Outlined.Person,
            title = "Profile",
            blurb = "These power your heart-rate zones, calorie estimates and recovery baselines. Keep them accurate.",
        ) {
            Column {
                FormRow(label = "Age") {
                    StepperField(
                        value = profile.age.toString(),
                        accessibility = "Age, ${profile.age} years",
                        // Bound to 13..100 to match iOS — and, since v4, age feeds the Fitness Age + Vitality
                        // engines which gate on age > 0, an unbounded stepper let an Android user drive age to
                        // 0/negative and silently switch both cards off with no explanation (code review).
                        onMinus = { mutate { profile.age = (profile.age - 1).coerceIn(13, 100) } },
                        onPlus = { mutate { profile.age = (profile.age + 1).coerceIn(13, 100) } },
                    )
                }
                RowDivider()
                FormRow(label = "Sex") {
                    SegmentedPillControl(
                        items = SEX_OPTIONS,
                        selection = SEX_OPTIONS.firstOrNull { it.tag == profile.sex } ?: SEX_OPTIONS[0],
                        label = { it.label },
                        onSelect = { mutate { profile.sex = it.tag } },
                    )
                }
                RowDivider()
                FormRow(label = "Weight") {
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
                RowDivider()
                FormRow(label = "Height") {
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
                RowDivider()
                // Waist (optional): the one extra body measure that unlocks the Fitness Age VO₂max
                // estimate. Unset (0) by design — the headline Fitness Age never needs it — so it shows
                // "Add" until entered, then steps like Height (inches in imperial, cm in metric).
                // First tap from unset seeds a typical adult waist rather than 1 cm.
                FormRow(label = "Waist (optional)") {
                    Column(horizontalAlignment = Alignment.End) {
                        val hasWaist = profile.waistCm > 0.0
                        if (unitSystem == UnitSystem.IMPERIAL) {
                            val totalInches = UnitFormatter.cmToInches(profile.waistCm).roundToInt()
                            StepperField(
                                value = if (hasWaist) "%d″".format(totalInches) else "Add",
                                accessibility = if (hasWaist) {
                                    "Waist, $totalInches inches"
                                } else {
                                    "Waist, not set — optional, adds your VO₂max estimate"
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
                                    "Waist, not set — optional, adds your VO₂max estimate"
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
                RowDivider()
                FormRow(label = "Max heart rate") {
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
                RowDivider()
                // Step calibration (#139/#132): daily steps = @57 counter ticks ÷ this divisor.
                // 1.0 = raw pass-through until the true 5/MG tick rate is known. The divisor goes
                // up to 30 because a 5/MG motion counter can overcount by ~24×; the stepper uses a
                // variable increment (fine near 1.0, coarse up top) so high values stay reachable.
                FormRow(label = "Step calibration") {
                    StepperField(
                        value = "%.1f".format(profile.stepTicksPerStep),
                        accessibility = "Step calibration, %.1f counter ticks per step"
                            .format(profile.stepTicksPerStep),
                        onMinus = { mutate { profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up = false) } },
                        onPlus = { mutate { profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up = true) } },
                    )
                }
                Text(
                    "Counter ticks per step — leave at 1.0 unless your steps run high. On a WHOOP 5/MG they can run very high (10× or more), so this goes up to 30. Walk a known 1,000 steps and divide NOOP's count by the real count to get your value.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
                RowDivider()
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
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 44.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { showStepsCalibration = true }
                        .semantics {
                            contentDescription =
                                "Steps estimate calibration. $stepsSummary. Opens the calibration screen."
                        }
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text("Steps estimate", style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
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
                    "For a WHOOP 4.0, which sends no step count: NOOP estimates steps from motion, calibrated to your phone. Tap to see how close it is and adjust it.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }

        // --- Units ---
        // Imperial/Metric display toggle + a separate temperature override. Display-only — nothing
        // stored changes; NOOP keeps everything in SI and converts at the point of display. Mirrors the
        // macOS Settings → Units card.
        SettingsSection(
            icon = Icons.Filled.Straighten,
            title = "Units",
            blurb = "Choose how distances, weights, heights, temperatures and Effort are shown. Your data is always stored the same way — this only changes the display.",
        ) {
            Column {
                FormRow(label = "Measurement system") {
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
                RowDivider()
                FormRow(label = "Temperature") {
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
                RowDivider()
                // Effort scale (#268) — NOOP's native 0–100 Effort or WHOOP's 0–21 Day Strain axis.
                // Display-only; the stored value never changes, so a flip just re-labels every read-out.
                FormRow(label = "Effort scale") {
                    SegmentedPillControl(
                        items = listOf(EffortScale.HUNDRED, EffortScale.WHOOP),
                        selection = effortScale,
                        label = { if (it == EffortScale.HUNDRED) "0–100" else "0–21" },
                        onSelect = {
                            effortScale = it
                            UnitPrefs.setEffortScale(context, it)
                        },
                    )
                }
            }
        }

        // --- Appearance (Theme) ---
        SettingsSection(
            icon = Icons.Filled.Brightness6,
            title = "Appearance",
            blurb = "Choose Light, Dark, or follow your system. Light keeps NOOP's gold on warm paper; Dark is the signature navy.",
        ) {
            FormRow(label = "Theme") {
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
            FormRow(label = "Chart colours") {
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
        }

        // --- App icon (v3 "Titanium & Gold") ---
        // Two staged launcher icons — machined titanium (default) and blued/dark-blue titanium. The
        // swap is done by enabling exactly one <activity-alias> (.IconDefault / .IconNavy) at runtime;
        // the launcher may take a beat (or briefly disappear/redraw) while it re-reads the icon.
        SettingsSection(
            icon = Icons.Filled.Palette,
            title = "App icon",
            blurb = "Choose how NOOP looks on your home screen. The launcher may take a moment to refresh the icon after you change it.",
        ) {
            FormRow(label = "Icon") {
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
        SettingsSection(
            icon = Icons.Filled.Sensors,
            title = "Strap",
            blurb = "NOOP pairs directly with your WHOOP over Bluetooth — no WHOOP app, no cloud.",
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
                            title = "Battery ${pct.roundToInt()}%" +
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
                    Button(
                        onClick = { requestScan() },
                        enabled = !live.scanning,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text(if (live.scanning) "Searching…" else "Re-scan", style = NoopType.captionNumber) }

                    OutlinedButton(
                        onClick = { vm.disconnect() },
                        enabled = live.connected || live.bonded,
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.statusCritical),
                    ) { Text("Disconnect", style = NoopType.captionNumber) }
                }

                // Rename the strap's BLE advertising name (WHOOP 4.0 only). Writes the name to the strap
                // firmware (cmd 77); it reboots to apply, so the new name shows on the next connect. Handy
                // for a second-hand band stuck on the previous owner's name. Reversible.
                if (live.connected && !live.whoop5Detected) {
                    var nameDraft by remember(live.advertisingName) { mutableStateOf(live.advertisingName ?: "") }
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Strap name", style = NoopType.subhead, color = Palette.textPrimary)
                        Text(
                            "Rename your strap's Bluetooth name — useful for a second-hand band. The strap " +
                                "reboots to apply, then reconnects with the new name.",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                        OutlinedTextField(
                            value = nameDraft,
                            onValueChange = { nameDraft = it.take(24) },
                            singleLine = true,
                            placeholder = { Text("WHOOP", style = NoopType.body, color = Palette.textTertiary) },
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
                            Button(
                                onClick = { vm.ble.renameStrap(nameDraft) },
                                enabled = live.bonded && nameDraft.isNotBlank(),
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = Palette.accent,
                                    contentColor = Palette.surfaceBase,
                                ),
                            ) { Text("Rename", style = NoopType.captionNumber) }
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
                            "Keep connected in the background",
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            "Keeps streaming from your strap with an ongoing notification, even after you close NOOP. Turn off to disconnect when the app is closed.",
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
                            "Continuous HRV capture",
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            "Keeps the detailed beat-to-beat stream running all day and night, not just while a live screen is open, so NOOP captures much more for overnight HRV, recovery and sleep. Uses more battery (your strap streams heart rate continuously). Needs \"Keep connected in the background\" on.",
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

                // Diagnostics: "Debug logging" mirrors the strap log to logcat (adb). Default OFF — a
                // normal user never needs to write the connection log to the system log; the in-app log
                // (and the "Share strap log" export below) work regardless. Developers flip this on to
                // watch the connection live over `adb logcat -s WhoopBleClient`.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Debug logging",
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            "Also write the strap log to the system log (logcat) for development over adb. Off by default — the in-app log and “Share strap log” below work either way.",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = debugLogging,
                        onCheckedChange = {
                            debugLogging = it
                            vm.setDebugLogging(it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = "Debug logging"
                        },
                    )
                }

                // Diagnostics: export the strap connection log so people can attach it to a bug report.
                OutlinedButton(
                    onClick = { LogExport.shareStrapLog(context, vm.ble.exportLogText()) },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.textSecondary),
                ) { Text("Share strap log (for bug reports)", style = NoopType.captionNumber) }
            }
        }

        // --- Experimental · WHOOP 5 / MG --- (hidden when the user is confidently on a 4.0, #22)
        if (showFiveMGControls) {
        SettingsSection(
            icon = Icons.Filled.Science,
            title = "Experimental · WHOOP 5 / MG",
            blurb = "Live heart rate already works on a WHOOP 5/MG strap. These probes go further and try to coax more out of it. They are guesses, off by default, and only ever touch a 5/MG strap — WHOOP 4.0 is never affected.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        "Try WHOOP 5/MG protocol probes",
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
                            contentDescription = "Try WHOOP 5/MG protocol probes"
                        },
                    )
                }
                Text(
                    "On a 5/MG connection NOOP will send a puffin realtime-stream request after the handshake, and log what comes back. If you have a 5/MG strap, turning this on and sharing your strap log helps map the protocol. No effect on WHOOP 4.0.",
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
                        "Broadcast heart rate (Garmin/ANT)",
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
                            contentDescription = "Broadcast heart rate"
                        },
                    )
                }
                Text(
                    "Makes your WHOOP 5.0/MG advertise its heart rate as a standard Bluetooth HR sensor, so a Garmin (Edge/watch), Zwift or gym equipment can use it during a workout. Applied on the next connection (and immediately if connected); writes the strap's whoop_live_hr_in_adv_ind_pkt flag. Reversible. 5/MG only.",
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )

                // --- R22 deep-data unlock — the one probe that writes to the strap. (#174) ---
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        "Unlock WHOOP 5/MG deep data (R22)",
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = deepData,
                        onCheckedChange = {
                            deepData = it
                            puffinExperiment.isDeepDataEnabled = it
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = "Unlock WHOOP 5/MG deep data"
                        },
                    )
                }
                Text(
                    "WHOOP 5/MG straps hand a fresh app only live heart rate. The official app switches on the deeper streams (high-rate HR + motion + history) by writing a set of feature flags — a sequence two independent projects have documented. With this on, the button below sends that exact sequence to your strap. Unlike everything else here it does write to the strap, but it's reversible (it only changes which data the strap emits) and is the same thing the official app does. Experimental — it may do nothing on your firmware.",
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
                if (deepData) {
                    Button(
                        onClick = { vm.ble.enableWhoop5DeepData() },
                        enabled = live.encryptedBond && live.worn,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                        ),
                    ) { Text("Send enable sequence to strap") }
                    Text(
                        if (!live.encryptedBond) "Needs the full encrypted bond — close the official WHOOP app and pair the strap to NOOP first (a live-HR-only link can't carry the unlock)."
                        else if (!live.worn) "Put the strap on first — the deep stream is on-wrist only."
                        else "Wear the strap, tap once, then let it sync and share your strap log.",
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )
                    // Live R22 telemetry (#174): proof of what the strap is doing right now.
                    if (live.r22FlagsAccepted > 0) {
                        Text(
                            if (live.r22FlagsAccepted >= 15) "✓ Strap accepted all 15 R22 flags"
                            else "Strap accepted ${live.r22FlagsAccepted}/15 R22 flags…",
                            style = NoopType.caption,
                            color = if (live.r22FlagsAccepted >= 15) Palette.statusPositive else Palette.textSecondary,
                        )
                    }
                    if (live.deepPacketsThisSession > 0) {
                        Text(
                            "${live.deepPacketsThisSession} type-0x2F historical-offload frame(s) seen outside our sync — these are history (e.g. another app pulling the strap's backlog), not a live R22 stream (#494).",
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                        )
                    } else if (live.r22FlagsAccepted >= 15) {
                        Text(
                            "Flags accepted, but the enable sequence doesn't start a separate live stream — the deep records arrive as part of the normal history sync (#494).",
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        "Record 5/MG raw capture (research)",
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
                            contentDescription = "Record 5/MG raw capture"
                        },
                    )
                }
                Text(
                    "Records the raw frames of each 5/MG history sync to a file on this phone, so you can share them and help NOOP learn to decode 5/MG sleep, recovery and strain. The file contains raw biometric frames (heart rate, R-R, skin temperature, motion) and the strap's own diagnostic text. Nothing leaves the phone unless you share it. Off by default.",
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
                OutlinedButton(
                    onClick = { LogExport.shareWhoop5Capture(context, live.whoop5Detected) },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.textSecondary),
                ) { Text("Share 5/MG capture (for the decode effort)", style = NoopType.captionNumber) }

                // One-tap "matched pair" export (#510): hands a reporter BOTH the raw capture file and
                // the strap log together (timestamped, same minute) so a protocol-mapping issue arrives
                // with the frames AND the context that produced them.
                OutlinedButton(
                    onClick = { LogExport.shareRawAndLog(context, vm.ble.exportLogText(), live.whoop5Detected) },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.textSecondary),
                ) { Text("Export raw + log (matched pair)", style = NoopType.captionNumber) }
            }
        }
        } // end if (showFiveMGControls)

        // --- Diagnostics (every model) --- the raw-sensor CSV export is split out of the 5/MG card so it
        // stays available on a WHOOP 4.0 too (#22): a 4.0 owner still needs it to share decoded streams.
        SettingsSection(
            icon = Icons.Filled.Science,
            title = "Diagnostics",
            blurb = "A read-only export of the decoded sensor streams NOOP already stores. Works on any strap — nothing is written to your device, and nothing is uploaded.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                // Diagnostics: dump the decoded per-sample sensor streams (last 24h) to one long-format
                // CSV so power users / external devs can prototype sleep/activity/VBT algorithms on real
                // data without a BLE stream (#308/#276/#322). On-device only; plain text, no BLE hex.
                OutlinedButton(
                    onClick = { scope.launch { RawSensorExport.export(context, vm.repo) } },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.textSecondary),
                ) { Text("Export raw sensor data (CSV)", style = NoopType.captionNumber) }
                Text(
                    "Saves the last 24h of decoded sensor samples (heart rate, R-R, motion, steps and any 5/MG deep streams you've unlocked) as one CSV you can share — for tinkering with your own data. Nothing leaves the phone unless you share it.",
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )

                // Haptic clock (#460): buzz the current time on the strap as a sequence of buzzes. No-ops
                // safely when disconnected, so it stays enabled regardless of connection (matches the
                // "Share strap log" row above, which also doesn't gate on a live strap). 12/24h follows the
                // phone's own clock setting.
                OutlinedButton(
                    onClick = {
                        vm.ble.buzzTimeNow(is24h = android.text.format.DateFormat.is24HourFormat(context))
                    },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.textSecondary),
                ) { Text("Buzz the time on your strap", style = NoopType.captionNumber) }
                Text(
                    "Feel the current time as a sequence of buzzes (#460). Does nothing unless your strap is connected.",
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }

        // --- Scheduled debug export (#510, maddognik) --- a daily, no-UI drop of the timestamped strap
        // log (+ raw .bin when a 5/MG capture exists) into the app's export folder at a time you choose, so
        // an intermittent overnight fault leaves a dated log waiting instead of needing a manual share. The
        // feature core lives in DebugExportScheduler/DebugExportSettings; this is just the controls. OFF by
        // default. SharedPreferences isn't reactive, so the Switch + time mirror into local state.
        SettingsSection(
            icon = Icons.Filled.Storage,
            title = "Scheduled debug export (#510)",
            blurb = "Once a day at a time you choose, NOOP writes a timestamped strap log (plus the raw 5/MG capture, if you have one) to its export folder — no sharing, nothing leaves the phone. Useful for chasing an intermittent overnight fault. Off by default.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Daily auto-export",
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            "Writes a timestamped strap log (and the raw .bin if a 5/MG capture exists) to the app's export folder once a day at the time below.",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = debugExportEnabled,
                        onCheckedChange = {
                            debugExportEnabled = it
                            debugExportSettings.enabled = it
                            DebugExportScheduler.reschedule(context)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = "Daily auto-export"
                        },
                    )
                }

                if (debugExportEnabled) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Export time", style = NoopType.subhead, color = Palette.textPrimary)
                            Text(
                                "The daily export runs at this time.",
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                        }
                        TimeChip(
                            minutes = debugExportMinutes,
                            accessibilityLabel = "Daily export time",
                            onPicked = {
                                debugExportMinutes = it
                                debugExportSettings.timeMinutes = it
                                DebugExportScheduler.applyTimeChange(context)
                            },
                        )
                    }
                }

                // "Export now" writes the dated file immediately (off the main thread, like the CSV export
                // above) and confirms with a Toast naming the folder, so the user sees the feature work
                // without waiting for the scheduled run.
                OutlinedButton(
                    onClick = {
                        scope.launch {
                            val files = withContext(Dispatchers.IO) {
                                LogExport.writeScheduledExport(context, vm.ble.exportLogText())
                            }
                            Toast.makeText(
                                context,
                                if (files.isNotEmpty()) "Wrote a dated debug export (${files.size} file${if (files.size == 1) "" else "s"}) to the app's export folder."
                                else "Couldn't write the debug export.",
                                Toast.LENGTH_LONG,
                            ).show()
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.textSecondary),
                ) { Text("Export now", style = NoopType.captionNumber) }
            }
        }

        // --- Trends report (#436) — shareable offline PDF over a date range. Self-contained
        // card (its own NoopCard + range picker + CTA), so it drops in without a SettingsSection wrapper.
        TrendsReportExportSection(vm)

        // --- Health & wellness (v5 opt-in toggles) ---
        SettingsSection(
            icon = Icons.Filled.Science,
            title = "Health & wellness",
            blurb = "Optional, on-device wellness signals. Each is off by default, computed only on this phone from data you already have, and never a medical diagnosis.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                ToggleRow(
                    title = "Illness heads-up",
                    detail = "Watches your resting heart rate, HRV and skin temperature for the pattern that often shows up before you feel unwell, and surfaces a gentle heads-up. An observation about your own numbers — not a diagnosis.",
                    checked = illnessWatch,
                    onCheckedChange = {
                        illnessWatch = it
                        vm.setIllnessWatchEnabled(it)
                    },
                )
                RowDivider()
                ToggleRow(
                    title = "Cycle awareness",
                    detail = "Reads a coarse menstrual-cycle phase from your nightly skin-temperature shift, on this device only. Awareness only — not contraception, not a fertility predictor, not a medical service.",
                    checked = cycleTracking,
                    onCheckedChange = {
                        cycleTracking = it
                        vm.setCycleTrackingEnabled(it)
                    },
                )
                RowDivider()
                ToggleRow(
                    title = "Stress check-ins (haptic)",
                    detail = "Lets NOOP notice a fresh HRV dip while you're still and offer a minute to breathe. \"Stress\" here is an autonomic proxy from your own baseline — never a diagnosis. The strap gives one light confirming buzz; no push notification.",
                    checked = stressCheckIn,
                    onCheckedChange = {
                        stressCheckIn = it
                        BiofeedbackPrefs.setCheckInEnabled(context, it)
                        // Turning the master off also disarms the auto-nudge sub-toggle so it can't fire.
                        if (!it) { stressAutoNudge = false; BiofeedbackPrefs.setAutoNudge(context, false) }
                    },
                )
                if (stressCheckIn) {
                    ToggleRow(
                        title = "Offer a breath automatically",
                        detail = "When a dip is detected, surface the check-in card on its own (rate-limited, quiet-hours aware). Off keeps it manual.",
                        checked = stressAutoNudge,
                        onCheckedChange = {
                            stressAutoNudge = it
                            BiofeedbackPrefs.setAutoNudge(context, it)
                        },
                    )
                }
                RowDivider()
                ToggleRow(
                    title = "Rhythm (experimental)",
                    detail = "An experimental picture of your beat-to-beat timing — a Poincaré scatter and plain regularity stats from quiet resting windows. Not an ECG and not a diagnosis; you'll read a short disclaimer and accept before it turns on.",
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
                RowDivider()
                ToggleRow(
                    title = "Share on-device signals with the Coach",
                    detail = "When the opt-in Coach is set up with your own key, also include a short summary of your strongest on-device patterns and Lab Book markers in its context. Summary only — no raw data leaves your phone. Requires the Coach's own data consent first.",
                    checked = coachSignals,
                    onCheckedChange = {
                        coachSignals = it
                        NoopPrefs.setCoachSignals(context, it)
                    },
                )
            }
        }

        SettingsSection(
            icon = Icons.Filled.Storage,
            title = "Backup & restore",
            blurb = "Move all your NOOP data to another phone. Export saves everything — history, sleeps, workouts, settings — to a single file you can copy across; import replaces this phone's data with a backup.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Button(
                        onClick = {
                            backupBusy = true
                            exportLauncher.launch("noop-backup-${java.time.LocalDate.now()}.noopbak")
                        },
                        enabled = !backupBusy,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text("Export…", style = NoopType.captionNumber) }

                    OutlinedButton(
                        onClick = {
                            backupBusy = true
                            importLauncher.launch(arrayOf("*/*"))
                        },
                        enabled = !backupBusy,
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                    ) { Text("Import…", style = NoopType.captionNumber) }

                    OutlinedButton(
                        onClick = {
                            backupBusy = true
                            csvExportLauncher.launch("noop-export-${java.time.LocalDate.now()}.zip")
                        },
                        enabled = !backupBusy,
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                    ) { Text("Export CSV…", style = NoopType.captionNumber) }

                    if (backupBusy) {
                        CircularProgressIndicator(
                            color = Palette.accent,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }

                NoteRow(
                    icon = Icons.Filled.Info,
                    iconTint = Palette.textTertiary,
                    text = "Importing overwrites everything currently on this phone. Your old data is kept in a side file just in case. NOOP needs a relaunch for an import to take effect. " +
                        "Export CSV writes a WHOOP-format zip of your days, sleeps, workouts and journal that re-imports into NOOP on Android or Mac — on-device computed rows are marked APPROXIMATE in its Source column; the .noopbak backup stays the lossless restore path.",
                )
            }
        }

        // --- About ---
        SettingsSection(
            icon = Icons.Filled.Info,
            title = "About",
            blurb = "NOOP — all your data, none of the cloud.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text("NOOP", style = NoopType.title2, color = Palette.textPrimary)
                    StatePill("v${BuildConfig.VERSION_NAME}", tone = StrandTone.Neutral, showsDot = false)
                }

                // Project home — NOOP's code, releases, issues and wiki now live on its own
                // independent forge at noop.fans (after the project's GitHub was suspended).
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.accent.copy(alpha = 0.10f))
                        .border(1.dp, Palette.accent.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
                        .clickable {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://noop.fans/NoopApp/noop"))
                            try {
                                context.startActivity(intent)
                            } catch (_: ActivityNotFoundException) {
                                Toast.makeText(context, "noop.fans/NoopApp/noop", Toast.LENGTH_LONG).show()
                            }
                        }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                        .semantics { contentDescription = "Project home and source at noop.fans" },
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Project home & source", style = NoopType.body, color = Palette.textPrimary)
                        Text(
                            "noop.fans — code, releases, issues and the wiki.",
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                }

                // Check for updates — a single, user-initiated call to the project's public releases API (noop.fans)
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
                                Text("Checking…", style = NoopType.captionNumber)
                            } else {
                                Text("Check for updates", style = NoopType.captionNumber)
                            }
                        }
                        when (val r = updResult) {
                            is UpdateCheck.Result.UpToDate ->
                                Text(
                                    "You're on the latest (${r.version}).",
                                    style = NoopType.footnote, color = Palette.textSecondary,
                                )
                            UpdateCheck.Result.Failed ->
                                Text(
                                    "Couldn't check. Try again.",
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
                                    "Version ${avail.version} is available",
                                    style = NoopType.subhead, color = Palette.textPrimary,
                                    modifier = Modifier.weight(1f),
                                )
                                Button(
                                    onClick = {
                                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(avail.url)))
                                    },
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                                    ),
                                ) { Text("Download", style = NoopType.captionNumber) }
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
                        "Checks GitHub for the latest version when you tap — nothing else is sent.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }

                Text(
                    "A standalone companion for your WHOOP. Everything stays on this phone — your history, your live stream, your numbers. Nothing is uploaded.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )

                // What's new — re-open the changelog sheet any time (macOS About parity).
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.surfaceInset)
                        .border(1.dp, Palette.hairline, RoundedCornerShape(10.dp))
                        .clickable { showWhatsNew = true }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                        .semantics { contentDescription = "What's new in NOOP ${AppChangelog.CURRENT_VERSION}" },
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
                            Text("What's new", style = NoopType.headline, color = Palette.textPrimary)
                            Text(
                                "Recent changes and what to expect",
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                        Text("›", style = NoopType.title2, color = Palette.accent)
                    }
                }

                // How your scores work — the honest explainer for Charge/Effort/Rest + the
                // confidence labels, opened any time (macOS/iOS About parity).
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.surfaceInset)
                        .border(1.dp, Palette.hairline, RoundedCornerShape(10.dp))
                        .clickable { showScoringGuide = true }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                        .semantics { contentDescription = "How your scores work" },
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
                            Text("How your scores work", style = NoopType.headline, color = Palette.textPrimary)
                            Text(
                                "Charge, Effort and Rest — and how they differ from WHOOP",
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
                        "NOOP is not a medical device. It is for informational and personal-insight purposes only and is not intended to diagnose, treat, cure or prevent any condition. Talk to a clinician for medical advice.",
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }

                RowDivider()

                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Overline("Built on")
                    AttributionRow(repo = "my-whoop", note = "WHOOP 4.0 protocol")
                    AttributionRow(repo = "goose", note = "WHOOP 5.0 protocol")
                }
                Text(
                    "Open-source BLE reverse-engineering work. Thank you.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )

                RowDivider()

                // Support link — opens the project's contact email (same address the
                // Support screen lists). NOOP is anonymous, so email is the support channel.
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.accent.copy(alpha = 0.10f))
                        .border(1.dp, Palette.accent.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
                        .clickable {
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
                        .semantics { contentDescription = "Contact support at $SUPPORT_EMAIL" },
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Support & contact", style = NoopType.headline, color = Palette.textPrimary)
                            Text(
                                "Questions, feedback, bugs — $SUPPORT_EMAIL",
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

// MARK: - Waist stepper (optional VO₂max input)

/** A typical adult waist (cm) used as the first value when stepping up from "unset" (0), so the field
 *  jumps to a sensible starting point rather than 1 cm. ~34" — the rough population midpoint. */
private const val WAIST_SEED_CM = 86.0

/** Step the waist by one centimetre, seeding [WAIST_SEED_CM] when starting from unset (0). Stepping
 *  down from the seed cannot go below the seed (it never silently re-enters the "unset" sentinel). */
private fun waistCmStep(current: Double, up: Boolean): Double {
    if (current <= 0.0) return if (up) WAIST_SEED_CM else 0.0
    return (current + if (up) 1.0 else -1.0).coerceAtLeast(WAIST_SEED_CM - 30.0)
}

/** Step the waist by one inch (entry unit in imperial; stored as cm), seeding [WAIST_SEED_CM] from
 *  unset. Snaps to whole inches so the up/down sequence is symmetric, mirroring the Height field. */
private fun waistInchesStep(current: Double, up: Boolean): Double {
    if (current <= 0.0) return if (up) WAIST_SEED_CM else 0.0
    val inches = UnitFormatter.cmToInches(current).roundToInt()
    val nextInches = (inches + if (up) 1 else -1)
    val nextCm = nextInches * UnitFormatter.CENTIMETERS_PER_INCH
    return nextCm.coerceAtLeast(WAIST_SEED_CM - 30.0)
}

// MARK: - Strap status helpers (mirror SettingsView's computed properties)

private fun strapStatusTitle(bonded: Boolean, connected: Boolean): String = when {
    bonded && connected -> "Bonded · streaming"
    connected -> "Connected"
    bonded -> "Bonded · idle"
    else -> "Disconnected"
}

private fun strapTone(bonded: Boolean, connected: Boolean): StrandTone = when {
    connected -> StrandTone.Positive
    bonded -> StrandTone.Warning
    else -> StrandTone.Critical
}

// `internal` (not private) so the unit test in the same package can assert the scanning branch.
internal fun strapStatusDetail(bonded: Boolean, connected: Boolean, scanning: Boolean): String = when {
    scanning -> "Searching for your WHOOP… make sure it's charged, on your wrist, and the official WHOOP app isn't connected to it."
    bonded && connected -> "Your strap is paired and sending data. Open Live for a real-time heart rate."
    connected -> "Connected. Finishing the secure pairing handshake…"
    bonded -> "Previously paired but not currently connected. Re-scan to reconnect."
    else -> "No strap connected. Put your WHOOP nearby and tap Re-scan to pair."
}

private fun batteryTone(pct: Double): StrandTone = when {
    pct <= 15 -> StrandTone.Critical
    pct <= 30 -> StrandTone.Warning
    else -> StrandTone.Positive
}

// MARK: - Sex options

private data class SexOption(val tag: String, val label: String)

private val SEX_OPTIONS = listOf(
    SexOption("male", "Male"),
    SexOption("female", "Female"),
    SexOption("nonbinary", "Non-binary"),
)

// MARK: - Section card (ports SettingsView's private SettingsSection)

/**
 * A grouped settings card: a "Settings" overline + icon + title header, an explanatory blurb, then
 * content. A faint brand-green wash anchors the card to NOOP's neutral chrome (mirrors macOS).
 */
@Composable
private fun SettingsSection(
    icon: ImageVector,
    title: String,
    blurb: String,
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Overline("Settings")
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                    Text(title, style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            Text(blurb, style = NoopType.subhead, color = Palette.textSecondary)
            content()
        }
    }
}

// MARK: - Labelled toggle row (title + detail + trailing Switch)

/**
 * A title + explanatory detail on the left with a trailing [Switch], matching the in-section toggle idiom
 * the Strap/Health Connect sections already use. Used by the v5 Health & wellness group so every opt-in
 * reads consistently. The switch colours mirror the rest of Settings (gold track when on).
 */
@Composable
private fun ToggleRow(
    title: String,
    detail: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = NoopType.subhead, color = Palette.textPrimary)
            Text(detail, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
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

// MARK: - Two-column form row (ports SettingsView's private FormRow)

/** Label on the left, control on the right — the two-column form feel. */
@Composable
private fun FormRow(label: String, control: @Composable () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            label,
            style = NoopType.body,
            color = Palette.textPrimary,
            modifier = Modifier.weight(1f),
        )
        control()
    }
}

// MARK: - Shared bits

@Composable
private fun RowDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .height(1.dp)
            .background(Palette.hairline),
    )
}

@Composable
private fun NoteRow(icon: ImageVector, iconTint: Color, text: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(16.dp))
        Text(text, style = NoopType.footnote, color = Palette.textSecondary)
    }
}

@Composable
private fun AttributionRow(repo: String, note: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.semantics { contentDescription = "$repo, $note" },
    ) {
        Text("›", style = NoopType.headline, color = Palette.accent)
        Text(repo, style = NoopType.mono(12f), color = Palette.textPrimary)
        Text("· $note", style = NoopType.footnote, color = Palette.textTertiary)
    }
}
